import Foundation

// MARK: - Errors / control-flow signals

struct BErr: Error { let msg: String; init(_ m: String) { msg = m } }
struct BreakSignal: Error {}
struct EndSignal: Error {}
struct StopSignal: Error {}

// MARK: - Values

enum Value {
    case num(Double)
    case str(String)

    var isStr: Bool { if case .str = self { return true }; return false }

    func asNum() throws -> Double {
        if case .num(let d) = self { return d }
        throw BErr("Type mismatch")
    }
    func asStr() throws -> String {
        if case .str(let s) = self { return s }
        throw BErr("Type mismatch")
    }
    func asInt() throws -> Int {
        let d = try asNum()
        guard d >= -2147483648, d <= 2147483647 else { throw BErr("Overflow") }
        return Int(d.rounded())
    }
}

// MARK: - Arrays

final class BasicArray {
    let dims: [Int]          // size of each dimension (maxIndex + 1)
    let isStr: Bool
    var nums: [Double] = []
    var strs: [String] = []
    let autoDimmed: Bool

    init(maxIndexes: [Int], isStr: Bool, autoDimmed: Bool) {
        self.dims = maxIndexes.map { $0 + 1 }
        self.isStr = isStr
        self.autoDimmed = autoDimmed
        let total = dims.reduce(1, *)
        if isStr { strs = Array(repeating: "", count: total) }
        else { nums = Array(repeating: 0, count: total) }
    }

    func flatIndex(_ subs: [Int]) throws -> Int {
        guard subs.count == dims.count else { throw BErr("Subscript out of range") }
        var f = 0
        for (i, s) in subs.enumerated() {
            guard s >= 0, s < dims[i] else { throw BErr("Subscript out of range") }
            f = f * dims[i] + s
        }
        return f
    }
}

// MARK: - Interpreter

final class Interpreter {
    let console: Console
    private let mmlPlayer: MMLPlaying

    // Program storage
    private(set) var program: [(num: Int, text: [Character])] = []
    private var lineIndex: [Int: Int] = [:]          // line number -> index in program
    private var autoNextLine: Int?
    private var autoIncrement = 10

    // Cursor (the "text pointer", like real MS BASIC)
    private var lineIdx = -1                          // -1 = immediate line
    private var chars: [Character] = []
    private var pos = 0
    private var immChars: [Character] = []

    // Runtime state
    private var vars: [String: Value] = [:]
    private var arrays: [String: BasicArray] = [:]
    private struct ForFrame { let name: String; let limit: Double; let step: Double; let lineIdx: Int; let pos: Int }
    private var forStack: [ForFrame] = []
    private var gosubStack: [(lineIdx: Int, pos: Int)] = []
    private var whileStack: [(lineIdx: Int, pos: Int)] = []
    private var dataItems: [(line: Int, raw: String)] = []
    private var dataPtr = 0
    private var fns: [String: (params: [String], body: [Character])] = [:]
    private var contPos: (lineIdx: Int, pos: Int)?
    private var stmtStart: (lineIdx: Int, pos: Int) = (-1, 0)
    private var mem = [UInt8](repeating: 0, count: 65536)
    private var tron = false
    private var graphicX = 0
    private var graphicY = 0
    private var graphicColor = 7

    // RNG
    private var rndState: UInt64 = 0x2545F4914F6CDD1D
    private var lastRnd: Double = 0.5

    // Execution speed governor (statements/sec), emulating a 1983-class machine.
    // Classic delay idioms like FOR W=1 TO 300: NEXT W only work if the
    // interpreter is not millions of times faster than the original hardware.
    // SPEED 0 disables the limit.
    private var speedLimit: Double = 4000
    private var paceVirtual: Double = 0
    private var paceReal: Double = ProcessInfo.processInfo.systemUptime

    // At the default execution speed, LIST advances at roughly one text row
    // per GUI refresh. This is close to the visible scrolling cadence of the
    // 8-bit machines SPEED 4000 is intended to represent.
    private static let classicSpeed: Double = 4000
    private static let classicListRowsPerSecond: Double = 30
    // Graphics are exposed in small batches at approximately SPEED pixels per
    // second. 64 pixels is short enough for the 30 Hz view to show progress,
    // while avoiding a lock acquisition for every individual dot.
    private static let graphicBatchSize = 64

    private static let reservedFuncs: Set<String> = [
        "ABS", "INT", "FIX", "SGN", "SQR", "SIN", "COS", "TAN", "ATN", "LOG", "EXP",
        "RND", "CINT", "CSNG", "CDBL", "PEEK", "FRE", "POS", "LEN", "ASC", "VAL",
        "INSTR", "CHR$", "STR$", "LEFT$", "RIGHT$", "MID$", "STRING$", "SPACE$", "SCRN$",
        "HEX$", "HEXCHR$", "OCT$", "INKEY$", "TIME$", "DATE$", "INPUT$", "CSRLIN", "POINT", "PLAY", "TAB", "SPC"
    ]

    init(console: Console, mmlPlayer: MMLPlaying = PSGPlayer()) {
        self.console = console
        self.mmlPlayer = mmlPlayer
        rndState = UInt64(Date().timeIntervalSince1970 * 1000).twisted
    }

    // MARK: - Top level

    func banner() {
        console.write("RetroBASIC Version 1.35\n")
        console.write("80's BASIC style interpreter, circa 1983\n")
        console.write("20289 Bytes free\n")
    }

    func repl() {
        banner()
        while true {
            if console.column != 0 { console.write("\n") }
            console.write("Ok\n")
            var executed = false
            while !executed {
                console.breakRequested = false
                do {
                    if let prompt = autoPrompt { console.write(prompt) }
                    guard let line = try console.readLine() else { return }
                    executed = processInput(line)
                } catch is BreakSignal {
                    cancelAuto()
                    console.write("\n")
                    executed = true
                } catch {
                    executed = true
                }
            }
        }
    }

    /// Feed one line as if typed. Returns true if a command executed (=> print "Ok").
    @discardableResult
    func processInput(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if let num = autoNextLine {
            if !line.isEmpty { storeLine(num, line) }
            guard num <= 65529 - autoIncrement else {
                cancelAuto()
                console.write("Overflow\n")
                return true
            }
            autoNextLine = num + autoIncrement
            return false
        }
        if line.isEmpty { return false }
        let cs = Array(line)
        if let d = cs.first, d.isASCIIDigit {
            var p = 0, n = 0
            while p < cs.count, cs[p].isASCIIDigit {
                n = min(n * 10 + Int(String(cs[p]))!, 9_999_999)
                p += 1
            }
            if n > 65529 { console.write("Syntax error\n"); return true }
            if p < cs.count, cs[p] == " " { p += 1 }
            let rest = String(cs[p...]).trimmingCharacters(in: .whitespaces)
            storeLine(n, rest)
            return false
        }
        handleImmediate(line)
        return autoNextLine == nil
    }

    private var autoPrompt: String? {
        guard let num = autoNextLine else { return nil }
        return lineIndex[num] == nil ? "\(num) " : "\(num)*"
    }

    private func cancelAuto() {
        autoNextLine = nil
    }

    func handleImmediate(_ line: String) {
        immChars = Array(Self.normalize(line))
        lineIdx = -1
        chars = immChars
        pos = 0
        do {
            try execLoop()
        } catch is EndSignal {
            // silent
        } catch is StopSignal {
            reportBreak()
        } catch is BreakSignal {
            contPos = stmtStart
            reportBreak()
        } catch let e as BErr {
            if let n = curLineNum { console.write("\(e.msg) in \(n)\n") }
            else { console.write("\(e.msg)\n") }
        } catch {
            console.write("Internal error\n")
        }
    }

    private func reportBreak() {
        if let n = curLineNum { console.write("Break in \(n)\n") }
        else { console.write("Break\n") }
    }

    private var curLineNum: Int? {
        (lineIdx >= 0 && lineIdx < program.count) ? program[lineIdx].num : nil
    }

    // MARK: - Program storage

    func storeLine(_ num: Int, _ rest: String) {
        contPos = nil
        if rest.isEmpty {
            if let idx = lineIndex[num] { program.remove(at: idx) }
        } else {
            let text = Array(Self.normalize(rest))
            if let idx = lineIndex[num] { program[idx].text = text }
            else {
                let at = program.firstIndex { $0.num > num } ?? program.count
                program.insert((num, text), at: at)
            }
        }
        rebuildIndex()
    }

    private func rebuildIndex() {
        lineIndex = [:]
        for (i, l) in program.enumerated() { lineIndex[l.num] = i }
    }

    /// Uppercase everything outside string literals (classic MS BASIC behavior).
    static func normalize(_ s: String) -> String {
        var out = ""
        var inQ = false
        for ch in RetroCharset.storageString(s) {
            if ch == "\"" { inQ.toggle(); out.append(ch) }
            else if inQ { out.append(ch) }
            else { out.append(contentsOf: ch.uppercased()) }
        }
        return out
    }

    // MARK: - Execution loop

    private func setLine(_ idx: Int) {
        lineIdx = idx
        chars = (idx == -1) ? immChars : program[idx].text
        pos = 0
    }

    private func restore(_ p: (lineIdx: Int, pos: Int)) {
        lineIdx = p.lineIdx
        chars = (p.lineIdx == -1) ? immChars : program[p.lineIdx].text
        pos = p.pos
    }

    private func gotoLine(_ n: Int) throws {
        guard let idx = lineIndex[n] else { throw BErr("Undefined line number") }
        setLine(idx)
    }

    private func execLoop() throws {
        while true {
            if console.breakRequested {
                console.breakRequested = false
                contPos = (lineIdx, pos)
                throw BreakSignal()
            }
            skipSpaces()
            if pos >= chars.count {
                if lineIdx < 0 { return }
                let next = lineIdx + 1
                if next >= program.count { return }
                setLine(next)
                if tron { console.write("[\(program[next].num)]") }
                continue
            }
            let c = chars[pos]
            if c == ":" { pos += 1; continue }
            if c == "'" { pos = chars.count; continue }
            if matchKeyword("ELSE") { pos = chars.count; continue }
            stmtStart = (lineIdx, pos)
            pace()
            try execStatement()
        }
    }

    /// Pace execution to `speedLimit` statements per second.
    private func pace() {
        guard speedLimit > 0 else { return }
        paceVirtual += 1.0 / speedLimit
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - paceReal
        let ahead = paceVirtual - elapsed
        if ahead > 0.004 {
            Thread.sleep(forTimeInterval: ahead)
        } else if ahead < -0.25 {
            // fell far behind (e.g., blocked in INPUT) — resync instead of bursting
            paceReal = now
            paceVirtual = 0
        }
    }

    // MARK: - Scanner helpers

    private func skipSpaces() {
        while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" { pos += 1 }
    }

    private func peekCh() -> Character? { pos < chars.count ? chars[pos] : nil }

    /// Match a keyword or symbol at the cursor (skipping leading spaces).
    /// Keywords ending in a letter require the next char to not be a letter.
    @discardableResult
    private func matchKeyword(_ kw: String) -> Bool {
        skipSpaces()
        let save = pos
        for k in kw {
            guard pos < chars.count, chars[pos] == k else { pos = save; return false }
            pos += 1
        }
        if let last = kw.last, last.isASCIIUpper,
           pos < chars.count, chars[pos].isASCIIUpper {
            pos = save; return false
        }
        return true
    }

    private func readIdent() -> String {
        var s = ""
        while pos < chars.count, chars[pos].isASCIIUpper || chars[pos].isASCIIDigit || chars[pos] == "." {
            s.append(chars[pos]); pos += 1
        }
        if pos < chars.count, "$%!#".contains(chars[pos]) {
            s.append(chars[pos]); pos += 1
        }
        return s
    }

    private func expectIdent() throws -> String {
        skipSpaces()
        guard let c = peekCh(), c.isASCIIUpper else { throw BErr("Syntax error") }
        return readIdent()
    }

    private func expect(_ ch: Character) throws {
        skipSpaces()
        guard pos < chars.count, chars[pos] == ch else { throw BErr("Syntax error") }
        pos += 1
    }

    private func tryLineNumber() -> Int? {
        skipSpaces()
        guard let c = peekCh(), c.isASCIIDigit else { return nil }
        var n = 0
        while pos < chars.count, chars[pos].isASCIIDigit {
            n = n * 10 + Int(String(chars[pos]))!
            pos += 1
        }
        return n
    }

    private func expectLineNumber() throws -> Int {
        guard let n = tryLineNumber() else { throw BErr("Syntax error") }
        return n
    }

    private func atStatementEnd() -> Bool {
        skipSpaces()
        if pos >= chars.count { return true }
        let c = chars[pos]
        if c == ":" || c == "'" { return true }
        let save = pos
        if matchKeyword("ELSE") { pos = save; return true }
        return false
    }

    private func skipStringLiteral() {
        // assumes chars[pos] == "\""
        pos += 1
        while pos < chars.count, chars[pos] != "\"" { pos += 1 }
        if pos < chars.count { pos += 1 }
    }

    // MARK: - Statement dispatch

    private func execStatement() throws {
        skipSpaces()
        guard pos < chars.count else { return }
        let c = chars[pos]
        if c == "?" { pos += 1; try stPrint(); return }
        if c == "'" { pos = chars.count; return }

        if matchKeyword("PRINT") { try stPrint(); return }
        if matchKeyword("LPRINT") { try stPrint(); return }
        if matchKeyword("LINE") {
            if matchKeyword("INPUT") { try stLineInput() }
            else { try stGraphicLine() }
            return
        }
        if matchKeyword("INPUT") { try stInput(); return }
        if matchKeyword("IF") { try stIf(); return }
        if matchKeyword("FOR") { try stFor(); return }
        if matchKeyword("NEXT") { try stNext(); return }
        if matchKeyword("WHILE") { try stWhile(); return }
        if matchKeyword("WEND") { try stWend(); return }
        if matchKeyword("GOTO") { try gotoLine(try expectLineNumber()); return }
        if matchKeyword("GOSUB") { try stGosub(); return }
        if matchKeyword("GO") {
            if matchKeyword("TO") { try gotoLine(try expectLineNumber()); return }
            if matchKeyword("SUB") { try stGosub(); return }
            throw BErr("Syntax error")
        }
        if matchKeyword("RETURN") { try stReturn(); return }
        if matchKeyword("ON") { try stOn(); return }
        if matchKeyword("DIM") { try stDim(); return }
        if matchKeyword("READ") { try stRead(); return }
        if matchKeyword("DATA") { skipDataStatement(); return }
        if matchKeyword("RESTORE") { stRestore(); return }
        if matchKeyword("REM") { pos = chars.count; return }
        if matchKeyword("END") { contPos = (lineIdx, pos); throw EndSignal() }
        if matchKeyword("STOP") { contPos = (lineIdx, pos); throw StopSignal() }
        if matchKeyword("CLS") { try stCls(); return }
        if matchKeyword("PSET") { try stPset(preset: false); return }
        if matchKeyword("PRESET") { try stPset(preset: true); return }
        if matchKeyword("CIRCLE") { try stCircle(); return }
        if matchKeyword("PAINT") { try stPaint(); return }
        if matchKeyword("LOCATE") { try stLocate(); return }
        if matchKeyword("COLOR") { try stColor(); return }
        if matchKeyword("BEEP") { try stBeep(); return }
        if matchKeyword("PLAY") { try stPlay(); return }
        if matchKeyword("CLEAR") { try stClear(); return }
        if matchKeyword("NEW") { stNew(); throw EndSignal() }
        if matchKeyword("LIST") { try stList(); return }
        if matchKeyword("RENUM") { try stRenum(); return }
        if matchKeyword("AUTO") { try stAuto(); return }
        if matchKeyword("RUN") { try stRun(); return }
        if matchKeyword("CONT") { try stCont(); return }
        if matchKeyword("SAVE") { try stSave(); return }
        if matchKeyword("LOAD") { try stLoad(); return }
        if matchKeyword("MERGE") { try stMerge(); return }
        if matchKeyword("FILES") { try stFiles(); return }
        if matchKeyword("KILL") { try stKill(); return }
        if matchKeyword("DEF") { try stDef(); return }
        if matchKeyword("RANDOMIZE") { try stRandomize(); return }
        if matchKeyword("SWAP") { try stSwap(); return }
        if matchKeyword("POKE") { try stPoke(); return }
        if matchKeyword("WIDTH") { try stWidth(); return }
        if matchKeyword("SPEED") { try stSpeed(); return }
        if matchKeyword("TRON") { tron = true; return }
        if matchKeyword("TROFF") { tron = false; return }
        if matchKeyword("ERASE") { try stErase(); return }
        if matchKeyword("LET") { try stLet(); return }
        if matchKeyword("ELSE") { pos = chars.count; return }

        if c.isASCIIUpper { try stLet(); return }
        throw BErr("Syntax error")
    }

    // MARK: - Statements

    private func stLet() throws {
        let lv = try parseLValue()
        try expect("=")
        let v = try expression()
        try assign(lv, v)
    }

    private enum LValue {
        case scalar(String)
        case element(String, [Int])
    }

    private func parseLValue() throws -> LValue {
        let name = try expectIdent()
        if Self.reservedFuncs.contains(name) { throw BErr("Syntax error") }
        skipSpaces()
        if peekCh() == "(" {
            let subs = try parseSubscripts()
            return .element(name, subs)
        }
        return .scalar(name)
    }

    private func parseSubscripts() throws -> [Int] {
        try expect("(")
        var subs: [Int] = []
        repeat { subs.append(try expression().asInt()) } while matchKeyword(",")
        try expect(")")
        return subs
    }

    private func assign(_ lv: LValue, _ v: Value) throws {
        switch lv {
        case .scalar(let name):
            vars[name] = try coerce(v, forName: name)
        case .element(let name, let subs):
            let arr = try arrayFor(name, subscriptCount: subs.count)
            let i = try arr.flatIndex(subs)
            if arr.isStr { arr.strs[i] = try v.asStr() }
            else { arr.nums[i] = try coerce(v, forName: name).asNum() }
        }
    }

    private func coerce(_ v: Value, forName name: String) throws -> Value {
        if name.hasSuffix("$") { return .str(try v.asStr()) }
        var d = try v.asNum()
        if name.hasSuffix("%") {
            guard d >= -32768.5, d < 32767.5 else { throw BErr("Overflow") }
            d = d.rounded()
        }
        return .num(d)
    }

    private func arrayFor(_ name: String, subscriptCount: Int) throws -> BasicArray {
        if let a = arrays[name] { return a }
        let a = BasicArray(maxIndexes: Array(repeating: 10, count: subscriptCount),
                           isStr: name.hasSuffix("$"), autoDimmed: true)
        arrays[name] = a
        return a
    }

    private func readVar(_ name: String) -> Value {
        vars[name] ?? (name.hasSuffix("$") ? .str("") : .num(0))
    }

    // PRINT
    private func stPrint() throws {
        if matchKeyword("USING") { try stPrintUsing(); return }
        var needNL = true
        while !atStatementEnd() {
            skipSpaces()
            if matchKeyword(";") { needNL = false; continue }
            if matchKeyword(",") {
                let zone = ((console.column / 14) + 1) * 14
                if zone >= console.width { console.write("\n") }
                else { console.write(String(repeating: " ", count: zone - console.column)) }
                needNL = false
                continue
            }
            if matchKeyword("TAB") {
                try expect("(")
                let n = try expression().asInt()
                try expect(")")
                let target = max(0, min(n - 1, console.width - 1))
                if console.column > target { console.write("\n") }
                if console.column < target {
                    console.write(String(repeating: " ", count: target - console.column))
                }
                needNL = true
                continue
            }
            if matchKeyword("SPC") {
                try expect("(")
                let n = try expression().asInt()
                try expect(")")
                if n > 0 { console.write(String(repeating: " ", count: n)) }
                needNL = true
                continue
            }
            let v = try expression()
            switch v {
            case .str(let s): console.write(s)
            case .num(let d): console.write(Self.numToString(d, signSpace: true) + " ")
            }
            needNL = true
        }
        if needNL { console.write("\n") }
    }

    private enum PrintUsingStringField {
        case first
        case fixed(Int)
        case all
    }

    private struct PrintUsingNumberField {
        let width: Int
        let digitsBeforeDecimal: Int
        let digitsAfterDecimal: Int
        let hasDecimalPoint: Bool
        let leadingPlus: Bool
        let trailingSign: Character?
        let starFill: Bool
        let currency: Bool
        let grouped: Bool
        let exponential: Bool
    }

    private enum PrintUsingPart {
        case literal(String)
        case string(PrintUsingStringField)
        case number(PrintUsingNumberField)

        var isField: Bool {
            switch self {
            case .literal: return false
            case .string, .number: return true
            }
        }
    }

    /// MS BASIC-style formatted output. The format is scanned cyclically when
    /// the expression list contains more values than it has data fields.
    private func stPrintUsing() throws {
        let format = try expression().asStr()
        try expect(";")
        let parts = try Self.parsePrintUsingFormat(format)
        guard parts.contains(where: \.isField), !atStatementEnd() else {
            throw BErr("Illegal function call")
        }

        var partIndex = 0
        var trailingSeparator: Character?
        while true {
            let value = try expression()
            try emitPrintUsing(value, parts: parts, index: &partIndex)

            skipSpaces()
            if atStatementEnd() { break }
            if peekCh() == ";" || peekCh() == "," {
                trailingSeparator = chars[pos]
                pos += 1
                if atStatementEnd() { break }
                trailingSeparator = nil
            }
            // As in classic BASIC, whitespace may separate expressions too.
        }

        emitPrintUsingTrailingLiterals(parts: parts, index: &partIndex)
        if trailingSeparator == "," {
            let zone = ((console.column / 14) + 1) * 14
            if zone >= console.width { console.write("\n") }
            else { console.write(String(repeating: " ", count: zone - console.column)) }
        } else if trailingSeparator != ";" {
            console.write("\n")
        }
    }

    private func emitPrintUsing(_ value: Value, parts: [PrintUsingPart],
                                index: inout Int) throws {
        while true {
            if index >= parts.count { index = 0 }
            switch parts[index] {
            case .literal(let text):
                console.write(text)
                index += 1
            case .string(let field):
                guard case .str(let text) = value else { throw BErr("Type mismatch") }
                console.write(Self.formatPrintUsingString(text, field: field))
                index += 1
                return
            case .number(let field):
                guard case .num(let number) = value else { throw BErr("Type mismatch") }
                console.write(try Self.formatPrintUsingNumber(number, field: field))
                index += 1
                return
            }
        }
    }

    /// After the final value, classic BASIC prints literal text following its
    /// field, but stops before the next unused field.
    private func emitPrintUsingTrailingLiterals(parts: [PrintUsingPart], index: inout Int) {
        while index < parts.count {
            guard case .literal(let text) = parts[index] else { return }
            console.write(text)
            index += 1
        }
    }

    private static func parsePrintUsingFormat(_ format: String) throws -> [PrintUsingPart] {
        let source = Array(format)
        var parts: [PrintUsingPart] = []
        var literal = ""
        var index = 0

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            parts.append(.literal(literal))
            literal = ""
        }

        func has(_ text: String, at start: Int) -> Bool {
            let target = Array(text)
            guard start + target.count <= source.count else { return false }
            for offset in target.indices where source[start + offset] != target[offset] {
                return false
            }
            return true
        }

        func numberField(at start: Int) throws -> (PrintUsingNumberField, Int)? {
            var cursor = start
            var leadingPlus = false
            var starFill = false
            var currency = false

            if has("**$", at: cursor) {
                starFill = true; currency = true; cursor += 3
            } else if has("**", at: cursor) {
                starFill = true; cursor += 2
            } else if has("$$", at: cursor) {
                currency = true; cursor += 2
            } else if cursor < source.count, source[cursor] == "+" {
                leadingPlus = true; cursor += 1
            } else if cursor >= source.count || (source[cursor] != "#" && source[cursor] != ".") {
                return nil
            }

            var before = 0
            var after = 0
            var hasDecimal = false
            var grouped = false
            while cursor < source.count {
                let ch = source[cursor]
                if ch == "#" {
                    if hasDecimal { after += 1 } else { before += 1 }
                    cursor += 1
                } else if ch == ".", !hasDecimal {
                    hasDecimal = true
                    cursor += 1
                } else if ch == ",", !hasDecimal,
                          cursor + 1 < source.count, source[cursor + 1] == "#" {
                    grouped = true
                    cursor += 1
                } else {
                    break
                }
            }

            let digitCount = before + after
            guard digitCount > 0 else { return nil }
            guard digitCount <= 24 else { throw BErr("Illegal function call") }

            var exponential = false
            if has("^^^^", at: cursor) {
                exponential = true
                cursor += 4
            }

            var trailingSign: Character?
            if cursor < source.count, source[cursor] == "+" || source[cursor] == "-" {
                trailingSign = source[cursor]
                cursor += 1
            }
            guard !(currency && exponential) else { throw BErr("Illegal function call") }

            return (PrintUsingNumberField(
                width: cursor - start,
                digitsBeforeDecimal: before,
                digitsAfterDecimal: after,
                hasDecimalPoint: hasDecimal,
                leadingPlus: leadingPlus,
                trailingSign: trailingSign,
                starFill: starFill,
                currency: currency,
                grouped: grouped,
                exponential: exponential
            ), cursor)
        }

        while index < source.count {
            let ch = source[index]
            if ch == "_" {
                if index + 1 < source.count {
                    literal.append(source[index + 1])
                    index += 2
                } else {
                    literal.append(ch)
                    index += 1
                }
                continue
            }
            if ch == "!" {
                flushLiteral()
                parts.append(.string(.first))
                index += 1
                continue
            }
            if ch == "&" {
                flushLiteral()
                parts.append(.string(.all))
                index += 1
                continue
            }
            if ch == "\\", let end = source[(index + 1)...].firstIndex(of: "\\") {
                flushLiteral()
                parts.append(.string(.fixed(end - index + 1)))
                index = end + 1
                continue
            }
            if let (field, end) = try numberField(at: index) {
                flushLiteral()
                parts.append(.number(field))
                index = end
                continue
            }
            literal.append(ch)
            index += 1
        }
        flushLiteral()
        return parts
    }

    private static func formatPrintUsingString(_ text: String,
                                               field: PrintUsingStringField) -> String {
        switch field {
        case .all:
            return text
        case .first:
            return text.first.map(String.init) ?? " "
        case .fixed(let width):
            let value = String(text.prefix(width))
            return value + String(repeating: " ", count: max(0, width - value.count))
        }
    }

    private static func formatPrintUsingNumber(_ value: Double,
                                               field: PrintUsingNumberField) throws -> String {
        guard value.isFinite else { throw BErr("Overflow") }
        let negative = value < 0
        let magnitude = abs(value)
        var digits: String

        if field.exponential {
            let explicitSign = field.leadingPlus || field.trailingSign != nil
            let effectiveBefore = explicitSign
                ? field.digitsBeforeDecimal
                : max(0, field.digitsBeforeDecimal - 1)
            let significantDigits = max(1, effectiveBefore + field.digitsAfterDecimal)
            var exponent = 0
            var mantissa = magnitude
            if magnitude != 0 {
                // Derive a normalized mantissa through libc formatting instead
                // of dividing by 10^exponent. The latter underflows for the
                // smallest subnormal Doubles (whose exponent is -324).
                let normalized = String(format: "%.16E",
                                        locale: Locale(identifier: "en_US_POSIX"),
                                        magnitude)
                let pieces = normalized.split(separator: "E", maxSplits: 1)
                guard pieces.count == 2,
                      let baseMantissa = Double(pieces[0]),
                      let baseExponent = Int(pieces[1]) else { throw BErr("Overflow") }
                if effectiveBefore > 0 {
                    exponent = baseExponent - effectiveBefore + 1
                    mantissa = baseMantissa * pow(10.0, Double(effectiveBefore - 1))
                } else {
                    exponent = baseExponent + 1
                    mantissa = baseMantissa / 10
                }
            }

            let scale = pow(10.0, Double(max(0, significantDigits - effectiveBefore)))
            mantissa = (mantissa * scale).rounded() / scale
            let threshold = pow(10.0, Double(effectiveBefore))
            if (effectiveBefore == 0 && mantissa >= 1) ||
               (effectiveBefore > 0 && mantissa >= threshold) {
                mantissa /= 10
                exponent += 1
            }

            let precision = field.digitsAfterDecimal
            digits = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"),
                            precision, mantissa)
            if effectiveBefore == 0, digits.hasPrefix("0.") { digits.removeFirst() }
            if field.hasDecimalPoint, precision == 0 { digits.append(".") }
            let exponentSign = exponent < 0 ? "-" : "+"
            let exponentDigits = String(format: "%02d", abs(exponent))
            digits += "E\(exponentSign)\(exponentDigits)"
        } else {
            digits = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"),
                            field.digitsAfterDecimal, magnitude)
            if field.digitsBeforeDecimal == 0, digits.hasPrefix("0.") {
                digits.removeFirst()
            }
            if field.hasDecimalPoint, field.digitsAfterDecimal == 0 { digits.append(".") }
            if field.grouped {
                let pieces = digits.split(separator: ".", maxSplits: 1,
                                          omittingEmptySubsequences: false)
                var integer = String(pieces[0])
                var grouped = ""
                while integer.count > 3 {
                    grouped = "," + integer.suffix(3) + grouped
                    integer.removeLast(3)
                }
                digits = integer + grouped
                if pieces.count == 2 { digits += "." + pieces[1] }
            }
        }

        var core = (field.currency ? "$" : "") + digits
        if field.leadingPlus {
            core = (negative ? "-" : "+") + core
        } else if let trailing = field.trailingSign {
            if trailing == "+" { core += negative ? "-" : "+" }
            else { core += negative ? "-" : " " }
        } else if negative {
            core = "-" + core
        }

        // Exponential fields without an explicit sign reserve one leading
        // digit position for a blank or minus sign.
        let reservedPositiveSign = field.exponential && !field.leadingPlus &&
            field.trailingSign == nil && !negative ? 1 : 0
        guard core.count <= field.width - reservedPositiveSign else { return "%" + core }
        let padding = String(repeating: field.starFill ? "*" : " ",
                             count: field.width - core.count)
        return padding + core
    }

    // INPUT
    private func stInput() throws {
        skipSpaces()
        var prompt = "? "
        if peekCh() == "\"" {
            let s = try stringLiteral()
            if matchKeyword(";") { prompt = s + "? " }
            else if matchKeyword(",") { prompt = s }
            else { throw BErr("Syntax error") }
        }
        var lvs: [LValue] = []
        repeat { lvs.append(try parseLValue()) } while matchKeyword(",")

        while true {
            console.write(prompt)
            guard let line = try console.readLine() else { throw BreakSignal() }
            let parts = Self.splitInputItems(line)
            if parts.count != lvs.count {
                console.write("?Redo from start\n")
                continue
            }
            var ok = true
            var pending: [(LValue, Value)] = []
            for (lv, part) in zip(lvs, parts) {
                let isStrTarget: Bool
                switch lv {
                case .scalar(let n): isStrTarget = n.hasSuffix("$")
                case .element(let n, _): isStrTarget = n.hasSuffix("$")
                }
                if isStrTarget {
                    pending.append((lv, .str(part)))
                } else {
                    let t = part.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { pending.append((lv, .num(0))) }
                    else if let d = Self.parseNumber(t) { pending.append((lv, .num(d))) }
                    else { ok = false; break }
                }
            }
            if !ok { console.write("?Redo from start\n"); continue }
            for (lv, v) in pending { try assign(lv, v) }
            return
        }
    }

    private static func splitInputItems(_ line: String) -> [String] {
        var items: [String] = []
        var cur = ""
        var inQ = false
        var quoted = false
        for ch in line {
            if ch == "\"" { inQ.toggle(); if inQ { quoted = true }; continue }
            if ch == ",", !inQ {
                items.append(quoted ? cur : cur.trimmingCharacters(in: .whitespaces))
                cur = ""; quoted = false
                continue
            }
            cur.append(ch)
        }
        items.append(quoted ? cur : cur.trimmingCharacters(in: .whitespaces))
        return items
    }

    private func stLineInput() throws {
        skipSpaces()
        var prompt = ""
        if peekCh() == "\"" {
            prompt = try stringLiteral()
            if !matchKeyword(";") { _ = matchKeyword(",") }
        }
        let lv = try parseLValue()
        console.write(prompt)
        guard let line = try console.readLine() else { throw BreakSignal() }
        try assign(lv, .str(line))
    }

    // IF
    private func stIf() throws {
        let cond = try expression().asNum()
        var thenIsGoto = false
        if matchKeyword("GOTO") { thenIsGoto = true }
        else if !matchKeyword("THEN") { throw BErr("Syntax error") }

        if cond != 0 {
            skipSpaces()
            if let n = tryLineNumber() { try gotoLine(n); return }
            if thenIsGoto { throw BErr("Syntax error") }
            return  // fall through: statements after THEN execute inline
        }
        // condition false: find matching ELSE on this line, else skip line
        if try scanToElse() {
            skipSpaces()
            if let n = tryLineNumber() { try gotoLine(n); return }
        } else {
            pos = chars.count
        }
    }

    /// Scan forward on the current line for the ELSE matching the current IF.
    /// Returns true (cursor just after ELSE) or false (no ELSE; cursor unspecified).
    private func scanToElse() throws -> Bool {
        var depth = 0
        while pos < chars.count {
            let c = chars[pos]
            if c == "\"" { skipStringLiteral(); continue }
            if c == "'" { return false }
            if c.isASCIIUpper {
                let w = readIdent()
                if w == "IF" { depth += 1 }
                else if w == "REM" { return false }
                else if w == "ELSE" {
                    if depth == 0 { return true }
                    depth -= 1
                }
                continue
            }
            pos += 1
        }
        return false
    }

    // FOR / NEXT
    private func stFor() throws {
        let name = try expectIdent()
        if name.hasSuffix("$") { throw BErr("Type mismatch") }
        try expect("=")
        let start = try expression().asNum()
        guard matchKeyword("TO") else { throw BErr("Syntax error") }
        let limit = try expression().asNum()
        var step = 1.0
        if matchKeyword("STEP") { step = try expression().asNum() }
        vars[name] = .num(start)
        if let i = forStack.lastIndex(where: { $0.name == name }) {
            forStack.removeSubrange(i...)
        }
        forStack.append(ForFrame(name: name, limit: limit, step: step, lineIdx: lineIdx, pos: pos))
    }

    private func stNext() throws {
        while true {
            skipSpaces()
            var name: String? = nil
            if let c = peekCh(), c.isASCIIUpper { name = readIdent() }
            if let nm = name {
                while let top = forStack.last, top.name != nm { forStack.removeLast() }
            }
            guard let frame = forStack.last else { throw BErr("NEXT without FOR") }
            let v = try readVar(frame.name).asNum() + frame.step
            vars[frame.name] = .num(v)
            let continues = frame.step >= 0 ? (v <= frame.limit) : (v >= frame.limit)
            if continues {
                restore((frame.lineIdx, frame.pos))
                return
            }
            forStack.removeLast()
            if matchKeyword(",") { continue }
            return
        }
    }

    // WHILE / WEND
    private func stWhile() throws {
        let condPos = stmtStart   // position of the WHILE statement itself
        let cond = try expression().asNum()
        if cond != 0 {
            if whileStack.last == nil || whileStack.last! != condPos {
                whileStack.append(condPos)
            }
        } else {
            if let top = whileStack.last, top == condPos { whileStack.removeLast() }
            try scanToWend()
        }
    }

    private func stWend() throws {
        guard let top = whileStack.last else { throw BErr("WEND without WHILE") }
        restore(top)
        // re-execute the WHILE statement (loop condition re-check)
    }

    private func scanToWend() throws {
        var depth = 1
        while true {
            if pos >= chars.count {
                if lineIdx < 0 || lineIdx + 1 >= program.count { throw BErr("WHILE without WEND") }
                setLine(lineIdx + 1)
                continue
            }
            let c = chars[pos]
            if c == "\"" { skipStringLiteral(); continue }
            if c == "'" { pos = chars.count; continue }
            if c.isASCIIUpper {
                let w = readIdent()
                if w == "WHILE" { depth += 1 }
                else if w == "WEND" { depth -= 1; if depth == 0 { return } }
                else if w == "REM" { pos = chars.count }
                else if w == "DATA" { skipDataStatement() }
                continue
            }
            pos += 1
        }
    }

    // GOSUB / RETURN / ON
    private func stGosub() throws {
        let n = try expectLineNumber()
        gosubStack.append((lineIdx, pos))
        try gotoLine(n)
    }

    private func stReturn() throws {
        guard let ret = gosubStack.popLast() else { throw BErr("RETURN without GOSUB") }
        if ret.lineIdx >= program.count { throw BErr("RETURN without GOSUB") }
        restore(ret)
    }

    private func stOn() throws {
        let n = try expression().asInt()
        let isGosub: Bool
        if matchKeyword("GOSUB") { isGosub = true }
        else if matchKeyword("GOTO") { isGosub = false }
        else { throw BErr("Syntax error") }
        var targets: [Int] = []
        repeat { targets.append(try expectLineNumber()) } while matchKeyword(",")
        guard n >= 0, n <= 255 else { throw BErr("Illegal function call") }
        if n >= 1, n <= targets.count {
            if isGosub { gosubStack.append((lineIdx, pos)) }
            try gotoLine(targets[n - 1])
        }
    }

    // DIM / ERASE
    private func stDim() throws {
        repeat {
            let name = try expectIdent()
            if Self.reservedFuncs.contains(name) { throw BErr("Syntax error") }
            let subs = try parseSubscripts()
            if arrays[name] != nil { throw BErr("Duplicate Definition") }
            arrays[name] = BasicArray(maxIndexes: subs, isStr: name.hasSuffix("$"), autoDimmed: false)
        } while matchKeyword(",")
    }

    private func stErase() throws {
        repeat {
            let name = try expectIdent()
            arrays.removeValue(forKey: name)
        } while matchKeyword(",")
    }

    // DATA / READ / RESTORE
    private func skipDataStatement() {
        while pos < chars.count {
            if chars[pos] == "\"" { skipStringLiteral(); continue }
            if chars[pos] == ":" { return }
            pos += 1
        }
    }

    private func collectData() {
        dataItems = []
        dataPtr = 0
        for (num, text) in program {
            var p = 0
            var atStmtStart = true
            while p < text.count {
                let c = text[p]
                if c == " " || c == "\t" { p += 1; continue }
                if c == "\"" {
                    p += 1
                    while p < text.count, text[p] != "\"" { p += 1 }
                    if p < text.count { p += 1 }
                    atStmtStart = false
                    continue
                }
                if c == ":" { p += 1; atStmtStart = true; continue }
                if c == "'" { break }
                if atStmtStart, c == "D", matchesWord(text, at: p, word: "DATA") {
                    p += 4
                    // parse items until ':' or EOL
                    var item = ""
                    var quoted = false
                    func flush() {
                        let v = quoted ? item : item.trimmingCharacters(in: .whitespaces)
                        dataItems.append((num, v))
                        item = ""; quoted = false
                    }
                    var inQ = false
                    while p < text.count {
                        let d = text[p]
                        if d == "\"" { inQ.toggle(); if inQ { quoted = true; item = "" }; p += 1; continue }
                        if inQ { item.append(d); p += 1; continue }
                        if d == ":" { break }
                        if d == "," { flush(); p += 1; continue }
                        item.append(d); p += 1
                    }
                    flush()
                    atStmtStart = false
                    continue
                }
                if c == "R", atStmtStart, matchesWord(text, at: p, word: "REM") { break }
                atStmtStart = false
                p += 1
            }
        }
    }

    private func matchesWord(_ text: [Character], at p: Int, word: String) -> Bool {
        let w = Array(word)
        guard p + w.count <= text.count else { return false }
        for i in 0..<w.count where text[p + i] != w[i] { return false }
        let after = p + w.count
        if after < text.count, text[after].isASCIIUpper { return false }
        return true
    }

    private func stRead() throws {
        repeat {
            let lv = try parseLValue()
            guard dataPtr < dataItems.count else { throw BErr("Out of DATA") }
            let raw = dataItems[dataPtr].raw
            dataPtr += 1
            let isStrTarget: Bool
            switch lv {
            case .scalar(let n): isStrTarget = n.hasSuffix("$")
            case .element(let n, _): isStrTarget = n.hasSuffix("$")
            }
            if isStrTarget { try assign(lv, .str(raw)) }
            else {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { try assign(lv, .num(0)) }
                else if let d = Self.parseNumber(t) { try assign(lv, .num(d)) }
                else { throw BErr("Type mismatch") }
            }
        } while matchKeyword(",")
    }

    private func stRestore() {
        if let n = tryLineNumber() {
            dataPtr = dataItems.firstIndex { $0.line >= n } ?? dataItems.count
        } else {
            dataPtr = 0
        }
    }

    // Screen
    private func stLocate() throws {
        let x = try expression().asInt()
        try expect(",")
        let y = try expression().asInt()
        if matchKeyword(",") { _ = try expression() }   // cursor visibility: ignored
        console.locate(max(0, min(x, console.width - 1)), max(0, min(y, 24)))
    }

    private func stColor() throws {
        let f = try expression().asInt()
        var background: Int? = nil
        if matchKeyword(",") { background = try expression().asInt() }
        if matchKeyword(",") { _ = try expression() }
        console.setColor(f & 7, background: background.map { $0 & 7 })
    }

    private func stWidth() throws {
        let columns = try expression().asInt()
        guard atStatementEnd() else { throw BErr("Syntax error") }
        guard columns == 40 || columns == 80 else { throw BErr("Illegal function call") }
        console.setWidth(columns)
        graphicX = 0; graphicY = 0
    }

    // WIDTH 40 = 320x200, WIDTH 80 = 640x200; digital RGB colours 0...7.
    private func graphicPoint(relativeTo base: (Int, Int)) throws -> (Int, Int) {
        let relative = matchKeyword("STEP")
        try expect("(")
        let x = try expression().asInt()
        try expect(",")
        let y = try expression().asInt()
        try expect(")")
        return relative ? (base.0 + x, base.1 + y) : (x, y)
    }

    private func requireGraphicPoint(_ point: (Int, Int)) throws {
        guard point.0 >= 0, point.0 < console.graphicsWidth,
              point.1 >= 0, point.1 < GraphicsSurface.height else {
            throw BErr("Illegal function call")
        }
    }

    /// The time assigned to one plotted graphics pixel. SPEED 0 deliberately
    /// returns nil so it preserves the former instantaneous drawing behaviour.
    static func graphicPixelInterval(forSpeed speed: Double) -> TimeInterval? {
        guard speed > 0 else { return nil }
        return 1.0 / speed
    }

    private func graphicLinePixels(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int)
        -> [(Int, Int)] {
        var pixels: [(Int, Int)] = []
        var x = x0, y = y0
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var error = dx + dy
        while true {
            pixels.append((x, y))
            if x == x1 && y == y1 { break }
            let twice = error * 2
            if twice >= dy { error += dy; x += sx }
            if twice <= dx { error += dx; y += sy }
        }
        return pixels
    }

    /// Plot pixels in redraw-friendly batches and keep the operation on a
    /// virtual deadline, just like statement pacing. A long graphics command
    /// remains interruptible with Ctrl-C while it is being drawn.
    private func drawGraphicPixels(_ pixels: [(Int, Int)], color: Int,
                                   interval: TimeInterval?, deadline: inout Double) throws {
        guard !pixels.isEmpty else { return }
        guard let interval else {
            console.plot(pixels, color: color)
            return
        }

        var offset = 0
        while offset < pixels.count {
            if console.breakRequested {
                console.breakRequested = false
                throw BreakSignal()
            }
            let end = min(offset + Self.graphicBatchSize, pixels.count)
            console.plot(Array(pixels[offset..<end]), color: color)
            deadline += Double(end - offset) * interval
            try paceGraphicDrawing(until: &deadline)
            offset = end
        }
    }

    /// Hu-BASIC tile data is eight pixels wide. Each row consists of three
    /// bytes in blue, red, green order; combining their bits produces one of
    /// the eight digital RGB palette indexes.
    private struct GraphicTile {
        let rows: [(blue: UInt8, red: UInt8, green: UInt8)]

        func color(atX x: Int, y: Int) -> Int {
            let row = rows[y % rows.count]
            let mask = UInt8(1 << (7 - (x & 7)))
            var color = 0
            if row.blue & mask != 0 { color |= 1 }
            if row.red & mask != 0 { color |= 2 }
            if row.green & mask != 0 { color |= 4 }
            return color
        }
    }

    private func graphicTile(from string: String) throws -> GraphicTile {
        let scalars = Array(string.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= 255, scalars.count % 3 == 0 else {
            throw BErr("Illegal function call")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(scalars.count)
        for scalar in scalars {
            guard scalar.value <= 255 else { throw BErr("Illegal function call") }
            bytes.append(UInt8(scalar.value))
        }
        var rows: [(blue: UInt8, red: UInt8, green: UInt8)] = []
        rows.reserveCapacity(bytes.count / 3)
        for offset in stride(from: 0, to: bytes.count, by: 3) {
            rows.append((bytes[offset], bytes[offset + 1], bytes[offset + 2]))
        }
        return GraphicTile(rows: rows)
    }

    /// Draw a screen-anchored Hu-BASIC tile over an arbitrary pixel set.
    /// Grouping each redraw-sized batch by palette index keeps Console's
    /// existing single-colour plot API and preserves SPEED pacing.
    private func drawGraphicPixels(_ pixels: [(Int, Int)], tile: GraphicTile,
                                   interval: TimeInterval?, deadline: inout Double) throws {
        guard !pixels.isEmpty else { return }
        let batchSize = interval == nil ? pixels.count : Self.graphicBatchSize
        var offset = 0
        while offset < pixels.count {
            if interval != nil, console.breakRequested {
                console.breakRequested = false
                throw BreakSignal()
            }
            let end = min(offset + batchSize, pixels.count)
            var byColor = [[(Int, Int)]](repeating: [], count: 8)
            for point in pixels[offset..<end] {
                byColor[tile.color(atX: point.0, y: point.1)].append(point)
            }
            for color in 0..<8 where !byColor[color].isEmpty {
                console.plot(byColor[color], color: color)
            }
            if let interval {
                deadline += Double(end - offset) * interval
                try paceGraphicDrawing(until: &deadline)
            }
            offset = end
        }
    }

    private func paceGraphicDrawing(until deadline: inout Double) throws {
        while true {
            if console.breakRequested {
                console.breakRequested = false
                throw BreakSignal()
            }
            let now = ProcessInfo.processInfo.systemUptime
            let remaining = deadline - now
            if remaining <= 0 {
                if remaining < -0.25 { deadline = now }
                return
            }
            // Very short waits accumulate into the next batch instead of
            // relying on sub-millisecond sleep precision.
            if remaining <= 0.004 { return }
            Thread.sleep(forTimeInterval: min(remaining, 0.01))
        }
    }

    /// Find a bounded paint region one horizontal scan line at a time. Keeping
    /// each span in left-to-right order gives PAINT the characteristic sweep
    /// of period BASIC implementations when drawing is paced by SPEED.
    static func horizontalPaintRegion(from start: (Int, Int), width: Int, height: Int,
                                      isBoundary: (Int, Int) -> Bool) -> [(Int, Int)] {
        guard width > 0, height > 0,
              start.0 >= 0, start.0 < width,
              start.1 >= 0, start.1 < height,
              !isBoundary(start.0, start.1) else { return [] }

        var visited = [Bool](repeating: false, count: width * height)
        var region: [(Int, Int)] = []
        var stack = [start]

        while let (seedX, y) = stack.popLast() {
            let seedIndex = y * width + seedX
            if visited[seedIndex] || isBoundary(seedX, y) { continue }

            var left = seedX
            while left > 0 {
                let x = left - 1
                if visited[y * width + x] || isBoundary(x, y) { break }
                left = x
            }

            var right = seedX
            while right + 1 < width {
                let x = right + 1
                if visited[y * width + x] || isBoundary(x, y) { break }
                right = x
            }

            for x in left...right {
                visited[y * width + x] = true
                region.append((x, y))
            }

            // Add one seed for every adjacent open span. The stack decides
            // which row comes next, but every emitted row remains horizontal.
            for adjacentY in [y - 1, y + 1] where adjacentY >= 0 && adjacentY < height {
                var x = left
                while x <= right {
                    let index = adjacentY * width + x
                    if visited[index] || isBoundary(x, adjacentY) {
                        x += 1
                        continue
                    }
                    stack.append((x, adjacentY))
                    repeat { x += 1 }
                    while x <= right && !visited[adjacentY * width + x]
                          && !isBoundary(x, adjacentY)
                }
            }
        }

        return region
    }

    private func optionalGraphicColor(default defaultColor: Int) throws -> Int {
        guard matchKeyword(",") else { return defaultColor }
        skipSpaces()
        if atStatementEnd() || peekCh() == "," { return defaultColor }
        let color = try expression().asInt()
        guard color >= 0, color <= 7 else { throw BErr("Illegal function call") }
        return color
    }

    private func stCls() throws {
        let mode = atStatementEnd() ? 3 : try expression().asInt()
        guard atStatementEnd(), mode >= 1, mode <= 3 else { throw BErr("Illegal function call") }
        if mode == 1 || mode == 3 { console.cls() }
        if mode == 2 || mode == 3 { console.clearGraphics() }
        graphicX = 0; graphicY = 0
    }

    private func stPset(preset: Bool) throws {
        let point = try graphicPoint(relativeTo: (graphicX, graphicY))
        try requireGraphicPoint(point)
        let color = try optionalGraphicColor(default: preset ? 0 : graphicColor)
        guard atStatementEnd() else { throw BErr("Syntax error") }
        let interval = Self.graphicPixelInterval(forSpeed: speedLimit)
        var deadline = ProcessInfo.processInfo.systemUptime
        try drawGraphicPixels([point], color: color, interval: interval, deadline: &deadline)
        graphicX = point.0; graphicY = point.1; graphicColor = color
    }

    private func stGraphicLine() throws {
        let start: (Int, Int)
        if matchKeyword("-") {
            start = (graphicX, graphicY)
        } else {
            start = try graphicPoint(relativeTo: (graphicX, graphicY))
            try expect("-")
        }
        let end = try graphicPoint(relativeTo: start)
        try requireGraphicPoint(start); try requireGraphicPoint(end)
        let paint: Value
        if matchKeyword(",") {
            skipSpaces()
            paint = (atStatementEnd() || peekCh() == ",") ? .num(Double(graphicColor))
                                                           : try expression()
        } else {
            paint = .num(Double(graphicColor))
        }
        var boxMode: String? = nil
        if matchKeyword(",") {
            if matchKeyword("BF") { boxMode = "BF" }
            else if matchKeyword("B") { boxMode = "B" }
            else { throw BErr("Syntax error") }
        }
        guard atStatementEnd() else { throw BErr("Syntax error") }
        let pixels: [(Int, Int)]
        if let boxMode, boxMode == "BF" {
            let left = min(start.0, end.0), right = max(start.0, end.0)
            let top = min(start.1, end.1), bottom = max(start.1, end.1)
            pixels = (top...bottom).flatMap { y in (left...right).map { ($0, y) } }
        } else if boxMode != nil {
            let left = min(start.0, end.0), right = max(start.0, end.0)
            let top = min(start.1, end.1), bottom = max(start.1, end.1)
            pixels = graphicLinePixels(left, top, right, top)
                   + graphicLinePixels(right, top, right, bottom)
                   + graphicLinePixels(right, bottom, left, bottom)
                   + graphicLinePixels(left, bottom, left, top)
        } else {
            pixels = graphicLinePixels(start.0, start.1, end.0, end.1)
        }
        let interval = Self.graphicPixelInterval(forSpeed: speedLimit)
        var deadline = ProcessInfo.processInfo.systemUptime
        switch paint {
        case .num:
            let color = try paint.asInt()
            guard color >= 0, color <= 7 else { throw BErr("Illegal function call") }
            try drawGraphicPixels(pixels, color: color, interval: interval, deadline: &deadline)
            graphicColor = color
        case .str(let pattern):
            guard boxMode == "BF" else { throw BErr("Type mismatch") }
            let tile = try graphicTile(from: pattern)
            try drawGraphicPixels(pixels, tile: tile, interval: interval, deadline: &deadline)
        }
        graphicX = end.0; graphicY = end.1
    }

    private func stCircle() throws {
        let center = try graphicPoint(relativeTo: (graphicX, graphicY))
        try requireGraphicPoint(center)
        try expect(",")
        let radius = try expression().asInt()
        guard radius >= 0, radius <= 4096 else { throw BErr("Illegal function call") }
        var color = graphicColor
        var start: Double? = nil, end: Double? = nil
        var aspect = console.graphicsWidth == 320 ? 0.8 : 0.4
        if matchKeyword(",") {
            skipSpaces()
            if peekCh() != "," { color = try expression().asInt() }
            if matchKeyword(",") {
                skipSpaces()
                if peekCh() != "," { start = try expression().asNum() }
                if matchKeyword(",") {
                    skipSpaces()
                    if peekCh() != "," { end = try expression().asNum() }
                    if matchKeyword(",") { aspect = try expression().asNum() }
                }
            }
        }
        guard color >= 0, color <= 7, aspect > 0, aspect <= 4,
              atStatementEnd() else { throw BErr("Illegal function call") }
        let ry = max(1, Int((Double(radius) * aspect).rounded()))
        let steps = max(24, Int(2 * Double.pi * Double(max(radius, ry)) * 1.5))
        let from = start ?? 0
        var to = end ?? (2 * Double.pi)
        if to < from { to += 2 * Double.pi }
        let pixels = (0...steps).map { i -> (Int, Int) in
            let angle = from + (to - from) * Double(i) / Double(steps)
            return (center.0 + Int((cos(angle) * Double(radius)).rounded()),
                    center.1 - Int((sin(angle) * Double(ry)).rounded()))
        }
        let interval = Self.graphicPixelInterval(forSpeed: speedLimit)
        var deadline = ProcessInfo.processInfo.systemUptime
        try drawGraphicPixels(pixels, color: color, interval: interval, deadline: &deadline)
        graphicX = center.0; graphicY = center.1; graphicColor = color
    }

    private func stPaint() throws {
        let point = try graphicPoint(relativeTo: (graphicX, graphicY))
        try requireGraphicPoint(point)
        var paint: Value = .num(Double(graphicColor))
        var borders: [Int] = []
        if matchKeyword(",") {
            skipSpaces()
            if peekCh() != ",", !atStatementEnd() { paint = try expression() }
            while matchKeyword(",") {
                let border = try expression().asInt()
                guard border >= 0, border <= 7 else { throw BErr("Illegal function call") }
                borders.append(border)
            }
        }
        guard atStatementEnd() else { throw BErr("Syntax error") }

        let fillColor: Int?
        let tile: GraphicTile?
        switch paint {
        case .num:
            let color = try paint.asInt()
            guard color >= 0, color <= 7 else { throw BErr("Illegal function call") }
            fillColor = color
            tile = nil
            if borders.isEmpty { borders = [color] }
            graphicColor = color
        case .str(let pattern):
            fillColor = nil
            tile = try graphicTile(from: pattern)
            if borders.isEmpty { borders = [graphicColor] }
        }

        let boundaryColors = Set(borders)
        guard !boundaryColors.contains(console.point(point.0, point.1)) else {
            graphicX = point.0; graphicY = point.1
            return
        }

        // Determine the whole bounded region before drawing it. A tile may
        // contain the original background or a boundary colour, so using the
        // newly painted pixels as flood-fill markers would terminate early.
        let region = Self.horizontalPaintRegion(
            from: point,
            width: console.graphicsWidth,
            height: GraphicsSurface.height
        ) { x, y in
            boundaryColors.contains(console.point(x, y))
        }

        let interval = Self.graphicPixelInterval(forSpeed: speedLimit)
        var deadline = ProcessInfo.processInfo.systemUptime
        if let fillColor {
            try drawGraphicPixels(region, color: fillColor, interval: interval, deadline: &deadline)
        } else if let tile {
            try drawGraphicPixels(region, tile: tile, interval: interval, deadline: &deadline)
        }
        graphicX = point.0; graphicY = point.1
    }

    // Program commands
    private func stNew() {
        program = []
        rebuildIndex()
        clearRuntime()
        contPos = nil
    }

    private func stClear() throws {
        // CLEAR [,size...] — args accepted and ignored
        if !atStatementEnd() {
            if !matchKeyword(",") { _ = try expression() }
            while matchKeyword(",") { _ = try? expression() }
        }
        clearRuntime()
    }

    private func clearRuntime() {
        vars = [:]
        arrays = [:]
        forStack = []
        gosubStack = []
        whileStack = []
        fns = [:]
        dataPtr = 0
    }

    private func stList() throws {
        var from = 0, to = 65529
        if let n = tryLineNumber() {
            from = n; to = n
            if matchKeyword("-") { to = tryLineNumber() ?? 65529 }
        } else if matchKeyword("-") {
            to = tryLineNumber() ?? 65529
        }
        var nextRowDeadline = ProcessInfo.processInfo.systemUptime
        for (num, text) in program where num >= from && num <= to {
            if console.breakRequested { console.breakRequested = false; throw BreakSignal() }
            try writeListedLine("\(num) \(String(text))\n", nextRowDeadline: &nextRowDeadline)
        }
    }

    /// The time assigned to one physical screen row of LIST output. Keeping
    /// this proportional to SPEED makes program execution and listing scroll
    /// together, while SPEED 0 retains the existing unlimited behaviour.
    static func listRowInterval(forSpeed speed: Double) -> TimeInterval? {
        guard speed > 0 else { return nil }
        return classicSpeed / (speed * classicListRowsPerSecond)
    }

    /// Write a listed program line in screen-row-sized pieces so wrapped lines
    /// do not jump several rows in a single redraw.
    private func writeListedLine(_ line: String, nextRowDeadline: inout Double) throws {
        let screenWidth = max(1, console.width)
        var output = ""
        var outputColumn = console.column

        for ch in line {
            if ch == "\n" {
                output.append(ch)
                console.write(output)
                output = ""
                outputColumn = 0
                try paceListedRow(nextRowDeadline: &nextRowDeadline)
                continue
            }

            let characterWidth = TermWidth.of(ch)
            if outputColumn + characterWidth > screenWidth {
                if !output.isEmpty {
                    console.write(output)
                    output = ""
                }
                try paceListedRow(nextRowDeadline: &nextRowDeadline)
                outputColumn = 0
            }

            output.append(ch)
            outputColumn += characterWidth
            if outputColumn >= screenWidth {
                console.write(output)
                output = ""
                outputColumn = 0
                try paceListedRow(nextRowDeadline: &nextRowDeadline)
            }
        }

        if !output.isEmpty { console.write(output) }
    }

    private func paceListedRow(nextRowDeadline: inout Double) throws {
        guard let interval = Self.listRowInterval(forSpeed: speedLimit) else { return }
        nextRowDeadline += interval

        while true {
            if console.breakRequested {
                console.breakRequested = false
                throw BreakSignal()
            }
            let now = ProcessInfo.processInfo.systemUptime
            let remaining = nextRowDeadline - now
            if remaining <= 0 {
                if remaining < -0.25 { nextRowDeadline = now }
                return
            }
            Thread.sleep(forTimeInterval: min(remaining, 0.01))
        }
    }

    private func stRenum() throws {
        guard lineIdx == -1 else { throw BErr("Illegal direct") }

        var newStart = 10
        var oldStart = 0
        var increment = 10

        skipSpaces()
        if peekCh() != ",", !atStatementEnd() {
            newStart = try expectLineNumber()
        }
        if matchKeyword(",") {
            skipSpaces()
            if peekCh() != ",", !atStatementEnd() {
                oldStart = try expectLineNumber()
            }
            if matchKeyword(",") {
                skipSpaces()
                if !atStatementEnd() { increment = try expectLineNumber() }
            }
        }
        guard atStatementEnd(), newStart >= 0, newStart <= 65529,
              oldStart >= 0, oldStart <= 65529, increment > 0 else {
            throw BErr("Illegal function call")
        }

        let selected = program.filter { $0.num >= oldStart }
        guard !selected.isEmpty else { return }
        guard selected.count - 1 <= (65529 - newStart) / increment else {
            throw BErr("Illegal function call")
        }

        let unchangedNumbers = Set(program.lazy.filter { $0.num < oldStart }.map(\.num))
        var mapping: [Int: Int] = [:]
        for (offset, line) in selected.enumerated() {
            let target = newStart + offset * increment
            guard !unchangedNumbers.contains(target) else { throw BErr("Illegal function call") }
            mapping[line.num] = target
        }

        program = program.map { line in
            (num: mapping[line.num] ?? line.num,
             text: renumberReferences(in: line.text, using: mapping))
        }.sorted { $0.num < $1.num }
        contPos = nil
        rebuildIndex()
    }

    private func stAuto() throws {
        guard lineIdx == -1 else { throw BErr("Illegal direct") }

        var start = 10
        var increment = 10

        skipSpaces()
        if peekCh() != ",", !atStatementEnd() {
            start = try expectLineNumber()
        }
        if matchKeyword(",") {
            skipSpaces()
            if !atStatementEnd() { increment = try expectLineNumber() }
            else { increment = autoIncrement }
        }
        guard atStatementEnd(), start >= 0, start <= 65529,
              increment > 0, increment <= 65529 else {
            throw BErr("Illegal function call")
        }

        autoNextLine = start
        autoIncrement = increment
    }

    /// Rewrite syntactic line-number operands without touching strings,
    /// apostrophe/REM comments, DATA values, or unrelated numeric literals.
    private func renumberReferences(in text: [Character], using mapping: [Int: Int]) -> [Character] {
        var out: [Character] = []
        var i = 0
        var atStatementStart = true

        func isIdentChar(_ c: Character) -> Bool {
            c.isASCIIUpper || c.isASCIIDigit || c == "." || "$%!#".contains(c)
        }

        func matches(_ word: String, at index: Int, requireBoundaryBefore: Bool = true) -> Bool {
            let w = Array(word)
            guard index + w.count <= text.count else { return false }
            if requireBoundaryBefore, index > 0, isIdentChar(text[index - 1]) { return false }
            for n in w.indices where text[index + n] != w[n] { return false }
            let after = index + w.count
            return after >= text.count || !text[after].isASCIIUpper
        }

        func appendRange(_ range: Range<Int>) {
            out.append(contentsOf: text[range])
        }

        func appendTargets(from index: inout Int, list: Bool) {
            while true {
                while index < text.count, text[index] == " " || text[index] == "\t" {
                    out.append(text[index]); index += 1
                }
                guard index < text.count, text[index].isASCIIDigit else { return }
                let start = index
                var number = 0
                while index < text.count, text[index].isASCIIDigit {
                    number = number * 10 + Int(String(text[index]))!
                    index += 1
                }
                if let replacement = mapping[number] { out.append(contentsOf: String(replacement)) }
                else { appendRange(start..<index) }
                guard list else { return }
                while index < text.count, text[index] == " " || text[index] == "\t" {
                    out.append(text[index]); index += 1
                }
                guard index < text.count, text[index] == "," else { return }
                out.append(text[index]); index += 1
            }
        }

        while i < text.count {
            let c = text[i]
            if c == "\"" {
                let start = i
                i += 1
                while i < text.count, text[i] != "\"" { i += 1 }
                if i < text.count { i += 1 }
                appendRange(start..<i)
                atStatementStart = false
                continue
            }
            if c == "'" {
                appendRange(i..<text.count)
                break
            }
            if c == ":" {
                out.append(c); i += 1
                atStatementStart = true
                continue
            }
            if c == " " || c == "\t" {
                out.append(c); i += 1
                continue
            }
            if atStatementStart, matches("REM", at: i, requireBoundaryBefore: false) {
                appendRange(i..<text.count)
                break
            }
            if atStatementStart, matches("DATA", at: i, requireBoundaryBefore: false) {
                let start = i
                var inString = false
                while i < text.count {
                    if text[i] == "\"" { inString.toggle() }
                    if text[i] == ":", !inString { break }
                    i += 1
                }
                appendRange(start..<i)
                atStatementStart = false
                continue
            }

            let boundaryBefore = atStatementStart || i == 0 || !isIdentChar(text[i - 1])
            if boundaryBefore, matches("GOSUB", at: i, requireBoundaryBefore: false) {
                appendRange(i..<(i + 5)); i += 5
                appendTargets(from: &i, list: true)
                atStatementStart = false
                continue
            }
            if boundaryBefore, matches("GOTO", at: i, requireBoundaryBefore: false) {
                appendRange(i..<(i + 4)); i += 4
                appendTargets(from: &i, list: true)
                atStatementStart = false
                continue
            }
            if boundaryBefore, matches("GO", at: i, requireBoundaryBefore: false) {
                let start = i
                var j = i + 2
                while j < text.count, text[j] == " " || text[j] == "\t" { j += 1 }
                if matches("TO", at: j, requireBoundaryBefore: false) ||
                   matches("SUB", at: j, requireBoundaryBefore: false) {
                    let length = matches("TO", at: j, requireBoundaryBefore: false) ? 2 : 3
                    i = j + length
                    appendRange(start..<i)
                    appendTargets(from: &i, list: true)
                    atStatementStart = false
                    continue
                }
            }
            if boundaryBefore, matches("RESTORE", at: i, requireBoundaryBefore: false) {
                appendRange(i..<(i + 7)); i += 7
                appendTargets(from: &i, list: false)
                atStatementStart = false
                continue
            }
            if boundaryBefore, matches("RUN", at: i, requireBoundaryBefore: false) {
                appendRange(i..<(i + 3)); i += 3
                appendTargets(from: &i, list: false)
                atStatementStart = false
                continue
            }
            if boundaryBefore, matches("THEN", at: i, requireBoundaryBefore: false) {
                appendRange(i..<(i + 4)); i += 4
                appendTargets(from: &i, list: false)
                atStatementStart = true
                continue
            }
            if boundaryBefore, matches("ELSE", at: i, requireBoundaryBefore: false) {
                appendRange(i..<(i + 4)); i += 4
                appendTargets(from: &i, list: false)
                atStatementStart = true
                continue
            }

            out.append(c)
            i += 1
            atStatementStart = false
        }
        return out
    }

    private func stRun() throws {
        skipSpaces()
        if peekCh() == "\"" {
            let name = try stringLiteral()
            try loadProgram(named: name)
        }
        var startIdx = 0
        if let n = tryLineNumber() {
            guard let idx = lineIndex[n] else { throw BErr("Undefined line number") }
            startIdx = idx
        }
        clearRuntime()
        collectData()
        contPos = nil
        guard !program.isEmpty else { throw EndSignal() }
        setLine(startIdx)
        if tron { console.write("[\(program[startIdx].num)]") }
    }

    private func stCont() throws {
        guard let p = contPos, p.lineIdx < program.count else { throw BErr("Can't continue") }
        contPos = nil
        restore(p)
    }

    // Files
    private var saveDir: URL {
        if let env = ProcessInfo.processInfo.environment["RETROBASIC_DIR"] {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/RetroBASIC")
    }

    private func fileURL(_ rawName: String) throws -> URL {
        var name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw BErr("Bad file name") }
        name = name.replacingOccurrences(of: "/", with: "_")
                   .replacingOccurrences(of: "..", with: "_")
        if !name.lowercased().hasSuffix(".bas") { name += ".bas" }
        return saveDir.appendingPathComponent(name)
    }

    private func stSave() throws {
        let name = try expression().asStr()
        let url = try fileURL(name)
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        var out = ""
        for (num, text) in program {
            out += "\(num) \(RetroCharset.fileString(String(text)))\n"
        }
        do { try out.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw BErr("Device I/O error") }
    }

    private func loadProgram(named name: String) throws {
        let url = try fileURL(name)
        guard let src = try? String(contentsOf: url, encoding: .utf8) else {
            throw BErr("File not found")
        }
        stNew()
        for line in src.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let f = t.first, f.isASCIIDigit else { continue }
            var p = t.startIndex, n = 0
            while p < t.endIndex, t[p].isASCIIDigit {
                n = min(n * 10 + Int(String(t[p]))!, 65529)
                p = t.index(after: p)
            }
            let rest = String(t[p...]).trimmingCharacters(in: .whitespaces)
            storeLine(n, rest)
        }
    }

    private func stLoad() throws {
        let name = try expression().asStr()
        try loadProgram(named: name)
        throw EndSignal()
    }

    private func stMerge() throws {
        let name = try expression().asStr()
        let url = try fileURL(name)
        guard let src = try? String(contentsOf: url, encoding: .utf8) else {
            throw BErr("File not found")
        }
        for line in src.split(separator: "\n", omittingEmptySubsequences: true) {
            _ = processInput(String(line))
        }
    }

    private func stFiles() throws {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: saveDir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".bas") }
            .sorted()
        if names.isEmpty { console.write("No files\n"); return }
        var col = 0
        for n in names {
            let cell = n.padding(toLength: max(n.count + 2, 18), withPad: " ", startingAt: 0)
            if col + cell.count > console.width { console.write("\n"); col = 0 }
            console.write(cell)
            col += cell.count
        }
        console.write("\n")
    }

    private func stKill() throws {
        let name = try expression().asStr()
        let url = try fileURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw BErr("File not found") }
        do { try FileManager.default.removeItem(at: url) }
        catch { throw BErr("Device I/O error") }
    }

    // DEF FN
    private func stDef() throws {
        skipSpaces()
        let name = try expectIdent()
        guard name.hasPrefix("FN"), name.count > 2 else { throw BErr("Syntax error") }
        try expect("(")
        var params: [String] = []
        repeat { params.append(try expectIdent()) } while matchKeyword(",")
        try expect(")")
        try expect("=")
        // capture body: rest of statement
        var body: [Character] = []
        while pos < chars.count {
            let c = chars[pos]
            if c == "\"" {
                let s = pos
                skipStringLiteral()
                body.append(contentsOf: chars[s..<pos])
                continue
            }
            if c == ":" || c == "'" { break }
            body.append(c); pos += 1
        }
        fns[name] = (params, body)
    }

    private func callFn(_ name: String) throws -> Value {
        guard let fn = fns[name] else { throw BErr("Undefined user function") }
        try expect("(")
        var args: [Value] = []
        repeat { args.append(try expression()) } while matchKeyword(",")
        try expect(")")
        guard args.count == fn.params.count else { throw BErr("Syntax error") }
        // save cursor + shadowed params
        let savedChars = chars, savedPos = pos
        var savedVars: [String: Value?] = [:]
        for (p, a) in zip(fn.params, args) {
            savedVars[p] = vars[p]
            vars[p] = try coerce(a, forName: p)
        }
        defer {
            chars = savedChars; pos = savedPos
            for (p, old) in savedVars {
                if let o = old { vars[p] = o } else { vars.removeValue(forKey: p) }
            }
        }
        chars = fn.body; pos = 0
        let v = try expression()
        if name.hasSuffix("$") { return .str(try v.asStr()) }
        return .num(try v.asNum())
    }

    // Misc statements
    private func stBeep() throws {
        guard atStatementEnd() else { throw BErr("Syntax error") }
        do {
            let result = try mmlPlayer.beep { self.console.breakRequested }
            if result == .interrupted {
                console.breakRequested = false
                contPos = (lineIdx, pos)
                throw BreakSignal()
            }
        } catch let error as MMLError {
            throw BErr(error.message)
        }
    }

    private func stPlay() throws {
        var channels = [try expression().asStr()]
        while matchKeyword(",") {
            guard channels.count < MMLCompiler.maximumChannels else { throw BErr("Syntax error") }
            channels.append(try expression().asStr())
        }
        guard atStatementEnd() else { throw BErr("Syntax error") }
        do {
            let result = try mmlPlayer.play(channels: channels) { self.console.breakRequested }
            if result == .interrupted {
                console.breakRequested = false
                contPos = (lineIdx, pos)
                throw BreakSignal()
            }
        } catch let error as MMLError {
            throw BErr(error.message)
        }
    }

    private func stRandomize() throws {
        if !atStatementEnd() {
            let n = try expression().asNum()
            rndState = (n.bitPattern &+ 0x9E3779B97F4A7C15).twisted
        } else {
            rndState = UInt64(Date().timeIntervalSince1970 * 1_000_000).twisted
        }
    }

    private func stSwap() throws {
        let a = try parseLValue()
        try expect(",")
        let b = try parseLValue()
        let va = try readLValue(a), vb = try readLValue(b)
        guard va.isStr == vb.isStr else { throw BErr("Type mismatch") }
        try assign(a, vb)
        try assign(b, va)
    }

    private func readLValue(_ lv: LValue) throws -> Value {
        switch lv {
        case .scalar(let n): return readVar(n)
        case .element(let n, let subs):
            let arr = try arrayFor(n, subscriptCount: subs.count)
            let i = try arr.flatIndex(subs)
            return arr.isStr ? .str(arr.strs[i]) : .num(arr.nums[i])
        }
    }

    // SPEED n — extension: set interpreter speed in statements/sec (0 = unlimited)
    private func stSpeed() throws {
        let n = try expression().asNum()
        guard n >= 0, n <= 100_000_000 else { throw BErr("Illegal function call") }
        speedLimit = n
        paceVirtual = 0
        paceReal = ProcessInfo.processInfo.systemUptime
    }

    private func stPoke() throws {
        let addr = try expression().asInt()
        try expect(",")
        let val = try expression().asInt()
        guard addr >= 0, addr < 65536, val >= 0, val <= 255 else { throw BErr("Illegal function call") }
        mem[addr] = UInt8(val)
    }

    // MARK: - Expressions
    // Precedence (loose → tight): XOR, OR, AND, NOT, relational, +/-, MOD, \, */, unary-, ^, primary

    func expression() throws -> Value { try exprXor() }

    private func exprXor() throws -> Value {
        var v = try exprOr()
        while matchKeyword("XOR") {
            let r = try exprOr()
            v = .num(Double(try logicInt(v) ^ (try logicInt(r))))
        }
        return v
    }

    private func exprOr() throws -> Value {
        var v = try exprAnd()
        while matchKeyword("OR") {
            let r = try exprAnd()
            v = .num(Double(try logicInt(v) | (try logicInt(r))))
        }
        return v
    }

    private func exprAnd() throws -> Value {
        var v = try exprNot()
        while matchKeyword("AND") {
            let r = try exprNot()
            v = .num(Double(try logicInt(v) & (try logicInt(r))))
        }
        return v
    }

    private func exprNot() throws -> Value {
        if matchKeyword("NOT") {
            let v = try exprNot()
            return .num(Double(~(try logicInt(v))))
        }
        return try exprRel()
    }

    private func logicInt(_ v: Value) throws -> Int32 {
        let d = try v.asNum()
        guard d >= -2147483648, d <= 2147483647 else { throw BErr("Overflow") }
        return Int32(d.rounded())
    }

    private func exprRel() throws -> Value {
        var v = try exprAdd()
        while true {
            skipSpaces()
            let op: String
            if matchKeyword("<=") || matchKeyword("=<") { op = "<=" }
            else if matchKeyword(">=") || matchKeyword("=>") { op = ">=" }
            else if matchKeyword("<>") || matchKeyword("><") { op = "<>" }
            else if matchKeyword("<") { op = "<" }
            else if matchKeyword(">") { op = ">" }
            else if matchKeyword("=") { op = "=" }
            else { return v }
            let r = try exprAdd()
            let res: Bool
            switch (v, r) {
            case (.num(let a), .num(let b)):
                switch op {
                case "<=": res = a <= b; case ">=": res = a >= b; case "<>": res = a != b
                case "<": res = a < b; case ">": res = a > b; default: res = a == b
                }
            case (.str(let a), .str(let b)):
                switch op {
                case "<=": res = a <= b; case ">=": res = a >= b; case "<>": res = a != b
                case "<": res = a < b; case ">": res = a > b; default: res = a == b
                }
            default:
                throw BErr("Type mismatch")
            }
            v = .num(res ? -1 : 0)
        }
    }

    private func exprAdd() throws -> Value {
        var v = try exprMod()
        while true {
            skipSpaces()
            if matchKeyword("+") {
                let r = try exprMod()
                switch (v, r) {
                case (.num(let a), .num(let b)): v = .num(try finite(a + b))
                case (.str(let a), .str(let b)): v = .str(a + b)
                default: throw BErr("Type mismatch")
                }
            } else if matchKeyword("-") {
                let r = try exprMod()
                v = .num(try finite(try v.asNum() - (try r.asNum())))
            } else {
                return v
            }
        }
    }

    private func exprMod() throws -> Value {
        var v = try exprIntDiv()
        while matchKeyword("MOD") {
            let a = try v.asNum().rounded()
            let b = try exprIntDiv().asNum().rounded()
            guard b != 0 else { throw BErr("Division by zero") }
            v = .num((a.truncatingRemainder(dividingBy: b)))
        }
        return v
    }

    private func exprIntDiv() throws -> Value {
        var v = try exprMul()
        while true {
            skipSpaces()
            guard pos < chars.count, chars[pos] == "\\" else { return v }
            pos += 1
            let a = try v.asNum().rounded()
            let b = try exprMul().asNum().rounded()
            guard b != 0 else { throw BErr("Division by zero") }
            v = .num((a / b).rounded(.towardZero))
        }
    }

    private func exprMul() throws -> Value {
        var v = try exprUnary()
        while true {
            skipSpaces()
            if matchKeyword("*") {
                v = .num(try finite(try v.asNum() * (try exprUnary().asNum())))
            } else if matchKeyword("/") {
                let b = try exprUnary().asNum()
                guard b != 0 else { throw BErr("Division by zero") }
                v = .num(try finite(try v.asNum() / b))
            } else {
                return v
            }
        }
    }

    private func exprUnary() throws -> Value {
        skipSpaces()
        if matchKeyword("-") {
            let v = try exprUnary()
            return .num(-(try v.asNum()))
        }
        if matchKeyword("+") { return try exprUnary() }
        return try exprPow()
    }

    private func exprPow() throws -> Value {
        var v = try primary()
        while matchKeyword("^") {
            skipSpaces()
            var neg = false
            if matchKeyword("-") { neg = true }
            var r = try primary().asNum()
            if neg { r = -r }
            let base = try v.asNum()
            let result = pow(base, r)
            guard result.isFinite else { throw BErr("Illegal function call") }
            v = .num(result)
        }
        return v
    }

    private func finite(_ d: Double) throws -> Double {
        guard d.isFinite else { throw BErr("Overflow") }
        return d
    }

    private func stringLiteral() throws -> String {
        skipSpaces()
        guard pos < chars.count, chars[pos] == "\"" else { throw BErr("Syntax error") }
        pos += 1
        var s = ""
        while pos < chars.count, chars[pos] != "\"" { s.append(chars[pos]); pos += 1 }
        if pos < chars.count { pos += 1 }
        return s
    }

    private func primary() throws -> Value {
        skipSpaces()
        guard let c = peekCh() else { throw BErr("Syntax error") }

        if c == "(" {
            pos += 1
            let v = try expression()
            try expect(")")
            return v
        }
        if c == "\"" { return .str(try stringLiteral()) }
        if c.isASCIIDigit || c == "." { return .num(try numberLiteral()) }
        if c == "&" { return .num(try radixLiteral()) }
        guard c.isASCIIUpper else { throw BErr("Syntax error") }

        let name = readIdent()
        if let v = try builtin(name) { return v }
        if name.hasPrefix("FN"), name.count > 2 { return try callFn(name) }

        skipSpaces()
        if peekCh() == "(" {
            let arr = try arrayFor(name, subscriptCount: try peekSubscriptCount())
            let subs = try parseSubscripts()
            let i = try arr.flatIndex(subs)
            return arr.isStr ? .str(arr.strs[i]) : .num(arr.nums[i])
        }
        return readVar(name)
    }

    private func peekSubscriptCount() throws -> Int {
        // count commas at depth 1 without consuming
        let save = pos
        defer { pos = save }
        try expect("(")
        var depth = 1, count = 1
        while pos < chars.count, depth > 0 {
            let c = chars[pos]
            if c == "\"" { skipStringLiteral(); continue }
            if c == "(" { depth += 1 }
            else if c == ")" { depth -= 1 }
            else if c == ",", depth == 1 { count += 1 }
            pos += 1
        }
        return count
    }

    private func numberLiteral() throws -> Double {
        var s = ""
        while pos < chars.count, chars[pos].isASCIIDigit { s.append(chars[pos]); pos += 1 }
        if pos < chars.count, chars[pos] == "." {
            s.append("."); pos += 1
            while pos < chars.count, chars[pos].isASCIIDigit { s.append(chars[pos]); pos += 1 }
        }
        if pos < chars.count, chars[pos] == "E" || chars[pos] == "D" {
            let save = pos
            var e = "E"; pos += 1
            if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" { e.append(chars[pos]); pos += 1 }
            if pos < chars.count, chars[pos].isASCIIDigit {
                while pos < chars.count, chars[pos].isASCIIDigit { e.append(chars[pos]); pos += 1 }
                s += e
            } else { pos = save }
        }
        if pos < chars.count, "%!#".contains(chars[pos]) { pos += 1 }
        guard let d = Double(s.isEmpty ? "0" : (s.first == "." ? "0" + s : s)) else { throw BErr("Syntax error") }
        return d
    }

    private func radixLiteral() throws -> Double {
        pos += 1   // consume '&'
        var radix = 8
        if pos < chars.count, chars[pos] == "H" { radix = 16; pos += 1 }
        else if pos < chars.count, chars[pos] == "O" { pos += 1 }
        var s = ""
        let hexChars = "0123456789ABCDEF"
        while pos < chars.count, hexChars.contains(chars[pos]) {
            if radix == 8, !("0"..."7").contains(chars[pos]) { break }
            s.append(chars[pos]); pos += 1
        }
        guard let v = Int(s, radix: radix) else { throw BErr("Syntax error") }
        return Double(v)
    }

    private static func parseNumber(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        if t.hasPrefix("&H"), let v = Int(t.dropFirst(2), radix: 16) { return Double(v) }
        return Double(t)
    }

    // MARK: - Built-in functions

    private func argList(min: Int, max: Int) throws -> [Value] {
        try expect("(")
        var args: [Value] = []
        repeat { args.append(try expression()) } while matchKeyword(",")
        try expect(")")
        guard args.count >= min, args.count <= max else { throw BErr("Syntax error") }
        return args
    }

    private func oneNum() throws -> Double { try argList(min: 1, max: 1)[0].asNum() }
    private func oneStr() throws -> String { try argList(min: 1, max: 1)[0].asStr() }

    private func builtin(_ name: String) throws -> Value? {
        switch name {
        case "ABS": return .num(abs(try oneNum()))
        case "INT": return .num((try oneNum()).rounded(.down))
        case "FIX": return .num((try oneNum()).rounded(.towardZero))
        case "SGN": let d = try oneNum(); return .num(d > 0 ? 1 : (d < 0 ? -1 : 0))
        case "SQR":
            let d = try oneNum()
            guard d >= 0 else { throw BErr("Illegal function call") }
            return .num(d.squareRoot())
        case "SIN": return .num(sin(try oneNum()))
        case "COS": return .num(cos(try oneNum()))
        case "TAN": return .num(tan(try oneNum()))
        case "ATN": return .num(atan(try oneNum()))
        case "LOG":
            let d = try oneNum()
            guard d > 0 else { throw BErr("Illegal function call") }
            return .num(Foundation.log(d))
        case "EXP": return .num(try finite(exp(try oneNum())))
        case "CINT":
            let d = try oneNum()
            guard d >= -32768.5, d < 32767.5 else { throw BErr("Overflow") }
            return .num(d.rounded())
        case "CSNG", "CDBL": return .num(try oneNum())
        case "RND":
            skipSpaces()
            if peekCh() == "(" {
                let x = try oneNum()
                if x == 0 { return .num(lastRnd) }
                if x < 0 { rndState = UInt64(bitPattern: Int64(x.bitPattern)).twisted }
                return .num(nextRnd())
            }
            return .num(nextRnd())
        case "PEEK":
            let a = try argList(min: 1, max: 1)[0].asInt()
            guard a >= 0, a < 65536 else { throw BErr("Illegal function call") }
            return .num(Double(mem[a]))
        case "FRE": _ = try argList(min: 1, max: 1); return .num(28815)
        case "POS": _ = try argList(min: 0, max: 1); return .num(Double(console.column + 1))
        case "CSRLIN": return .num(Double(console.row + 1))
        case "POINT":
            let a = try argList(min: 2, max: 2)
            return .num(Double(console.point(try a[0].asInt(), try a[1].asInt())))
        case "SCRN$":
            let a = try argList(min: 3, max: 3)
            let x = try a[0].asInt()
            let y = try a[1].asInt()
            let count = try a[2].asInt()
            guard x >= 0, x < console.width, y >= 0, y < 25,
                  count >= 0, count <= 255 else {
                throw BErr("Illegal function call")
            }
            return .str(console.readText(x, y, count: count))
        case "PLAY":
            let channel = try argList(min: 1, max: 1)[0].asInt()
            guard channel >= 0, channel <= MMLCompiler.maximumChannels else {
                throw BErr("Illegal function call")
            }
            return .num(mmlPlayer.isPlaying(channel: channel) ? -1 : 0)
        case "LEN": return .num(Double(RetroCharset.length(of: try oneStr())))
        case "ASC":
            let s = try oneStr()
            guard let first = RetroCharset.storageString(s).first else {
                throw BErr("Illegal function call")
            }
            if let byte = RetroCharset.byte(for: first) { return .num(Double(byte)) }
            guard let scalar = first.unicodeScalars.first else {
                throw BErr("Illegal function call")
            }
            return .num(Double(scalar.value))
        case "VAL":
            let s = try oneStr().trimmingCharacters(in: .whitespaces)
            var t = ""
            var seenE = false, seenDot = false
            for (i, ch) in s.enumerated() {
                if ch.isASCIIDigit { t.append(ch) }
                else if (ch == "+" || ch == "-"), i == 0 || t.uppercased().hasSuffix("E") { t.append(ch) }
                else if ch == ".", !seenDot, !seenE { seenDot = true; t.append(ch) }
                else if (ch == "E" || ch == "e"), !seenE, !t.isEmpty { seenE = true; t.append(ch) }
                else { break }
            }
            while let l = t.last, "Ee+-.".contains(l) { t.removeLast() }
            return .num(Double(t) ?? 0)
        case "CHR$":
            let n = try argList(min: 1, max: 1)[0].asInt()
            guard n >= 0 else { throw BErr("Illegal function call") }
            if n <= 0xFF { return .str(String(RetroCharset.character(forByte: UInt8(n)))) }
            guard n <= 0x10FFFF, let u = UnicodeScalar(n) else {
                throw BErr("Illegal function call")
            }
            return .str(RetroCharset.storageString(String(Character(u))))
        case "HEXCHR$":
            let source = try oneStr()
            var digits: [UInt8] = []
            digits.reserveCapacity(source.utf8.count)
            for scalar in source.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                let value = scalar.value
                switch value {
                case 48...57: digits.append(UInt8(value - 48))
                case 65...70: digits.append(UInt8(value - 65 + 10))
                case 97...102: digits.append(UInt8(value - 97 + 10))
                default: throw BErr("Illegal function call")
                }
            }
            guard digits.count % 2 == 0 else { throw BErr("Illegal function call") }
            var output = String.UnicodeScalarView()
            for offset in stride(from: 0, to: digits.count, by: 2) {
                let byte = UInt32(digits[offset] << 4 | digits[offset + 1])
                output.append(UnicodeScalar(byte)!)
            }
            return .str(String(output))
        case "STR$": return .str(Self.numToString(try oneNum(), signSpace: true))
        case "LEFT$":
            let a = try argList(min: 2, max: 2)
            let s = try a[0].asStr(); let n = try a[1].asInt()
            guard n >= 0 else { throw BErr("Illegal function call") }
            return .str(String(s.prefix(n)))
        case "RIGHT$":
            let a = try argList(min: 2, max: 2)
            let s = try a[0].asStr(); let n = try a[1].asInt()
            guard n >= 0 else { throw BErr("Illegal function call") }
            return .str(String(s.suffix(n)))
        case "MID$":
            let a = try argList(min: 2, max: 3)
            let s = Array(try a[0].asStr())
            let i = try a[1].asInt()
            guard i >= 1 else { throw BErr("Illegal function call") }
            let l = a.count == 3 ? try a[2].asInt() : Int.max
            guard l >= 0 else { throw BErr("Illegal function call") }
            if i > s.count { return .str("") }
            let end = min(s.count, l == Int.max ? s.count : i - 1 + l)
            return .str(String(s[(i - 1)..<end]))
        case "INSTR":
            let a = try argList(min: 2, max: 3)
            var start = 1, hi: String, ni: String
            if a.count == 3 {
                start = try a[0].asInt(); hi = try a[1].asStr(); ni = try a[2].asStr()
            } else {
                hi = try a[0].asStr(); ni = try a[1].asStr()
            }
            guard start >= 1 else { throw BErr("Illegal function call") }
            let h = Array(hi)
            if start > h.count { return .num(0) }
            if ni.isEmpty { return .num(Double(start)) }
            let sub = String(h[(start - 1)...])
            if let r = sub.range(of: ni) {
                let off = sub.distance(from: sub.startIndex, to: r.lowerBound)
                return .num(Double(start + off))
            }
            return .num(0)
        case "STRING$":
            let a = try argList(min: 2, max: 2)
            let n = try a[0].asInt()
            guard n >= 0, n <= 4096 else { throw BErr("Illegal function call") }
            let ch: Character
            if case .str(let s) = a[1] {
                guard let f = RetroCharset.storageString(s).first else {
                    throw BErr("Illegal function call")
                }
                ch = f
            } else {
                let code = try a[1].asInt()
                guard code >= 0 else { throw BErr("Illegal function call") }
                if code <= 0xFF {
                    ch = RetroCharset.character(forByte: UInt8(code))
                } else {
                    guard let u = UnicodeScalar(code) else { throw BErr("Illegal function call") }
                    ch = Character(u)
                }
            }
            return .str(String(repeating: String(ch), count: n))
        case "SPACE$":
            let n = try argList(min: 1, max: 1)[0].asInt()
            guard n >= 0, n <= 4096 else { throw BErr("Illegal function call") }
            return .str(String(repeating: " ", count: n))
        case "HEX$": return .str(String(try argList(min: 1, max: 1)[0].asInt(), radix: 16).uppercased())
        case "OCT$": return .str(String(try argList(min: 1, max: 1)[0].asInt(), radix: 8))
        case "INKEY$": return .str(console.inkey())
        case "INPUT$":
            let n = try argList(min: 1, max: 1)[0].asInt()
            guard n >= 1, n <= 255 else { throw BErr("Illegal function call") }
            var s = ""
            for _ in 0..<n {
                let ch = try console.readKey()
                if ch == "\u{03}" { throw BreakSignal() }
                s.append(ch)
            }
            return .str(s)
        case "TIME$":
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            return .str(f.string(from: Date()))
        case "DATE$":
            let f = DateFormatter(); f.dateFormat = "MM-dd-yyyy"
            return .str(f.string(from: Date()))
        default:
            return nil
        }
    }

    private func nextRnd() -> Double {
        rndState = rndState &* 6364136223846793005 &+ 1442695040888963407
        lastRnd = Double(rndState >> 33) / Double(UInt64(1) << 31)
        return lastRnd
    }

    // MARK: - Number formatting (MS BASIC style)

    static func numToString(_ d: Double, signSpace: Bool) -> String {
        var body: String
        if d == d.rounded(), abs(d) < 1e16 {
            body = String(format: "%.0f", d)
            if body == "-0" { body = "0" }
        } else {
            body = String(format: "%.7G", d)
            // strip leading zero: 0.5 -> .5, -0.5 -> -.5 (classic MS style)
            if body.hasPrefix("0.") { body.removeFirst() }
            else if body.hasPrefix("-0.") { body = "-" + body.dropFirst(2) }
        }
        if signSpace, !body.hasPrefix("-") { body = " " + body }
        return body
    }
}

// MARK: - Small helpers

extension Character {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
    var isASCIIUpper: Bool { self >= "A" && self <= "Z" }
}

extension UInt64 {
    /// splitmix64-style scramble for seeding
    var twisted: UInt64 {
        var z = self &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
