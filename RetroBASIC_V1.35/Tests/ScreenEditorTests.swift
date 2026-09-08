import Cocoa

@main
struct ScreenEditorTests {
    static func expect(_ actual: String, _ expected: String, _ name: String) {
        guard actual == expected else {
            fatalError("\(name): expected [\(expected)], got [\(actual)]")
        }
    }

    static func main() {
        editListedProgramLine()
        preserveWrappedLine()
        stripInputPrompt()
        preserveWideCharacters()
        insertAndShiftText()
        deleteAndCloseGap()
        backspaceAndCloseGap()
        insertAcrossWrappedLine()
        insertWideCharacter()
        switchScreenWidth()
        editWrappedLineAt40Columns()
        keepWindowSizeAcrossWidths()
        showCursorOnlyDuringLineInput()
        changeBackgroundColor()
        drawGraphicsPrimitives()
        convertHexCharacterStrings()
        paintUsesHorizontalScanLines()
        drawHuBasicTilePatterns()
        clearTextAndGraphicsSeparately()
        renderGraphicsLayer()
        persistCRTEffectSetting()
        preserveRetroCharacterBytes()
        useRetroCodesInStringFunctions()
        readTextScreenWithScrn()
        saveAndLoadRetroCharacters()
        composeCharactersBeforePaletteCommit()
        rejectRemovedScreenCommand()
        renumberProgramAndReferences()
        renumberWithDefaults()
        rejectInvalidRenumbering()
        executeRenumberedProgram()
        generateAutomaticLineNumbers()
        reuseAutomaticLineIncrement()
        preserveExistingLinesDuringAuto()
        rejectInvalidAutoArguments()
        rejectAutoInsideProgram()
        rejectUnsafeDimensions()
        rejectOversizedLineNumbers()
        rejectDirectStatementsDuringMerge()
        formatPrintUsingNumbers()
        formatPrintUsingNumericDecorations()
        formatPrintUsingStringsAndLiterals()
        repeatPrintUsingFormatAndControlNewline()
        rejectInvalidPrintUsingFormats()
        scaleListScrollingWithSpeed()
        scaleGraphicsDrawingWithSpeed()
        trackProgramArrowState()
        consumeBreakOnlyOnce()
        print("ScreenEditorTests: OK")
    }

    static func preserveRetroCharacterBytes() {
        let storedKana = RetroCharset.storageString("ｶﾞ")
        let bytes = storedKana.compactMap { RetroCharset.byte(for: $0) }
        guard storedKana.count == 2, bytes == [0xB6, 0xDE],
              RetroCharset.displayString(storedKana) == "ｶﾞ" else {
            fatalError("halfwidth dakuten was not preserved as two retro bytes")
        }

        let spade = RetroCharset.character(forByte: 0xE8)
        guard RetroCharset.byte(for: spade) == 0xE8,
              RetroCharset.displayString(String(spade)) == "♠",
              RetroCharset.fileString(String(spade)) == String(spade),
              RetroFont.glyph(forByte: 0xE8) == [0x08, 0x1C, 0x3E, 0x7F,
                                                 0x7F, 0x1C, 0x3E, 0x00] else {
            fatalError("GRPH character mapping or glyph was not preserved")
        }
    }

    static func useRetroCodesInStringFunctions() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.handleImmediate("IF LEN(\"ｶﾞ\")=2 AND ASC(\"ｱ\")=177 AND ASC(\"ﾞ\")=222 THEN PRINT \"OK\"")
        expect(firstScreenLine(core), "OK", "retro LEN and ASC")

        interpreter.handleImmediate("CLS:PRINT CHR$(&HB6);CHR$(&HDE);CHR$(&HE8)")
        expect(firstScreenLine(core), "ｶﾞ♠", "retro CHR$")
    }

    static func readTextScreenWithScrn() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.handleImmediate("SPEED 0")

        interpreter.handleImmediate("CLS:LOCATE 0,0:PRINT \"ABCDEFGHIJKLMNOPQRSTU\";")
        interpreter.handleImmediate("A$=SCRN$(0,0,10):LOCATE 0,1:PRINT A$;")
        guard core.readText(0, 1, count: 10) == "ABCDEFGHIJ" else {
            fatalError("SCRN$ did not read text cells")
        }

        interpreter.handleImmediate("WIDTH 40:LOCATE 38,2:PRINT \"ABCD\";")
        interpreter.handleImmediate("B$=SCRN$(38,2,4):LOCATE 0,4:PRINT B$;")
        guard core.readText(0, 4, count: 4) == "ABCD" else {
            fatalError("SCRN$ did not continue across a text row")
        }

        interpreter.handleImmediate("IF SCRN$(0,0,0)=\"\" THEN LOCATE 0,5:PRINT \"EMPTY\";")
        guard core.readText(0, 5, count: 5) == "EMPTY" else {
            fatalError("SCRN$ did not return an empty string for count zero")
        }

        interpreter.handleImmediate("PRINT SCRN$(0,0,256)")
        guard core.screenText.contains("Illegal function call") else {
            fatalError("SCRN$ accepted a count above 255")
        }
    }

    static func saveAndLoadRetroCharacters() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetroBASIC-charset-\(UUID().uuidString)")
        setenv("RETROBASIC_DIR", directory.path, 1)
        defer {
            unsetenv("RETROBASIC_DIR")
            try? FileManager.default.removeItem(at: directory)
        }

        let spade = RetroCharset.character(forByte: 0xE8)
        let source = "10 PRINT \"\(RetroCharset.storageString("ｶﾞ"))\(spade)\""
        let interpreter = Interpreter(console: TerminalConsole(core: TermCore()))
        interpreter.processInput(source)
        interpreter.handleImmediate("SAVE \"CHARSET\"")

        let loaded = Interpreter(console: TerminalConsole(core: TermCore()))
        loaded.handleImmediate("LOAD \"CHARSET\"")
        guard loaded.program.count == 1,
              String(loaded.program[0].text).contains(String(spade)),
              RetroCharset.displayString(String(loaded.program[0].text)).contains("ｶﾞ♠") else {
            fatalError("SAVE/LOAD did not preserve retro characters")
        }
    }

    static func composeCharactersBeforePaletteCommit() {
        _ = NSApplication.shared
        let core = TermCore()
        let terminal = TerminalView(core: core)
        let palette = CharacterPaletteController(terminalView: terminal)

        palette.appendCharacter(0xB1)
        palette.appendCharacter(0xDE)
        guard palette.bufferedCodes == [0xB1, 0xDE], core.popKeyNonBlocking() == nil else {
            fatalError("character palette committed before GO")
        }

        palette.removeLastBufferedCharacter()
        guard palette.bufferedCodes == [0xB1] else {
            fatalError("character palette backspace did not remove the last character")
        }

        palette.appendCharacter(0xE8)
        palette.commitBufferedCharacters()
        guard palette.bufferedCodes.isEmpty,
              core.popKeyNonBlocking() == RetroCharset.character(forByte: 0xB1),
              core.popKeyNonBlocking() == RetroCharset.character(forByte: 0xE8),
              core.popKeyNonBlocking() == nil else {
            fatalError("character palette did not commit its buffer through the keyboard queue")
        }
    }

    static func firstScreenLine(_ core: TermCore) -> String {
        core.screenText.components(separatedBy: "\n")[0]
    }

    static func formatPrintUsingNumbers() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))

        interpreter.handleImmediate("PRINT USING \"##.##|##.##|##.##\";.78;10.2;987.654")
        expect(firstScreenLine(core), " 0.78|10.20|%987.65", "PRINT USING fixed numbers")

        interpreter.handleImmediate("CLS:PRINT USING \"#,###.##\";1234.5")
        expect(firstScreenLine(core), "1,234.50", "PRINT USING grouped number")
    }

    static func formatPrintUsingNumericDecorations() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))

        interpreter.handleImmediate("PRINT USING \"+##.##|##.##-|**$##.##\";-68.95;-7.01;2.34")
        expect(firstScreenLine(core), "-68.95| 7.01-|***$2.34",
               "PRINT USING signs and currency")

        interpreter.handleImmediate("CLS:PRINT USING \"##.##^^^^|+.##^^^^\";234.56;123")
        expect(firstScreenLine(core), " 2.35E+02|+.12E+03", "PRINT USING exponential")

        interpreter.handleImmediate("CLS:PRINT USING \"##.##^^^^\";5E-324")
        expect(firstScreenLine(core), "%5.00E-324", "PRINT USING subnormal exponent")
    }

    static func formatPrintUsingStringsAndLiterals() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))

        interpreter.handleImmediate("PRINT USING \"!|\\  \\|&\";\"LOOK\";\"OUTSIDE\";\"ALL\"")
        expect(firstScreenLine(core), "L|OUTS|ALL", "PRINT USING string fields")

        interpreter.handleImmediate("CLS:PRINT USING \"_!##.##_!\";12.34")
        expect(firstScreenLine(core), "!12.34!", "PRINT USING escaped literals")
    }

    static func repeatPrintUsingFormatAndControlNewline() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))

        interpreter.handleImmediate("F$=\"X##Y\":PRINT USING F$;1;2")
        expect(firstScreenLine(core), "X 1YX 2Y", "PRINT USING repeated format")

        interpreter.handleImmediate("CLS:PRINT USING \"##\";1;:PRINT \"X\"")
        expect(firstScreenLine(core), " 1X", "PRINT USING trailing semicolon")
    }

    static func rejectInvalidPrintUsingFormats() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))

        interpreter.handleImmediate("PRINT USING \"NO FIELD\";1")
        interpreter.handleImmediate("PRINT USING \"#########################\";1")
        interpreter.handleImmediate("PRINT USING \"##\";\"WRONG\"")
        let screen = core.screenText
        guard screen.contains("Illegal function call"), screen.contains("Type mismatch") else {
            fatalError("PRINT USING accepted an invalid format or field type")
        }
    }

    static func scaleListScrollingWithSpeed() {
        guard let normal = Interpreter.listRowInterval(forSpeed: 4000),
              let half = Interpreter.listRowInterval(forSpeed: 2000),
              let double = Interpreter.listRowInterval(forSpeed: 8000),
              abs(normal - 1.0 / 30.0) < 0.000_001,
              abs(half - normal * 2) < 0.000_001,
              abs(double - normal / 2) < 0.000_001,
              Interpreter.listRowInterval(forSpeed: 0) == nil else {
            fatalError("SPEED did not scale LIST scrolling")
        }
    }

    static func scaleGraphicsDrawingWithSpeed() {
        guard let normal = Interpreter.graphicPixelInterval(forSpeed: 4000),
              let half = Interpreter.graphicPixelInterval(forSpeed: 2000),
              let double = Interpreter.graphicPixelInterval(forSpeed: 8000),
              abs(normal - 1.0 / 4000.0) < 0.000_001,
              abs(half - normal * 2) < 0.000_001,
              abs(double - normal / 2) < 0.000_001,
              Interpreter.graphicPixelInterval(forSpeed: 0) == nil else {
            fatalError("SPEED did not scale graphics drawing")
        }
    }

    static func consumeBreakOnlyOnce() {
        let core = TermCore()
        let console = TerminalConsole(core: core)

        core.pushBreak()
        core.pushBreak() // simulate key repeat before the interpreter polls
        guard console.breakRequested else { fatalError("break was not requested") }
        console.breakRequested = false
        guard !console.breakRequested, core.popKeyNonBlocking() == nil else {
            fatalError("consumed break leaked into the next input prompt")
        }
    }

    static func trackProgramArrowState() {
        let core = TermCore()
        let console = TerminalConsole(core: core)
        let left: Character = "\u{1D}"
        let right: Character = "\u{1C}"

        core.pressProgramKey(left, isRepeat: false)
        expect(console.inkey(), String(left), "held arrow initial poll")
        expect(console.inkey(), String(left), "held arrow repeated poll")

        core.pressProgramKey(right, isRepeat: false)
        expect(console.inkey(), String(right), "most recently pressed arrow")
        core.pressProgramKey(left, isRepeat: true)
        expect(console.inkey(), String(right), "autorepeat does not change direction priority")

        core.releaseProgramKey(right)
        expect(console.inkey(), String(left), "previously held arrow resumes")
        core.releaseProgramKey(left)
        expect(console.inkey(), "", "released arrow stops immediately")

        core.pressProgramKey(right, isRepeat: false)
        guard core.popKeyBlocking() == right else {
            fatalError("blocking key input did not receive program arrow press")
        }
        core.releaseProgramKey(right)

        core.pressProgramKey(left, isRepeat: false)
        core.pushKey("A")
        expect(console.inkey(), "A", "ordinary key queue remains FIFO-based")
        expect(console.inkey(), String(left), "held arrow survives ordinary key input")
        core.beginLineInput()
        expect(console.inkey(), "", "line input clears program arrow state")
        core.cancelLineInput()
    }

    static func editListedProgramLine() {
        let core = TermCore()
        core.putRaw("10 PRINT \"HELLO\"\nOk\n")
        core.beginLineInput()
        core.setCursor(11, 0)
        core.putEditCharacter("A")
        expect(core.finishLineInput(), "10 PRINT \"HALLO\"", "listed line edit")
    }

    static func preserveWrappedLine() {
        let core = TermCore()
        let listed = String(repeating: "A", count: 80) + "TAIL"
        core.putRaw(listed + "\nOk\n")
        core.beginLineInput()
        core.setCursor(2, 1)
        expect(core.finishLineInput(), listed, "wrapped line")
    }

    static func stripInputPrompt() {
        let core = TermCore()
        core.putRaw("VALUE? ")
        core.beginLineInput()
        core.putEditCharacter("4")
        core.putEditCharacter("2")
        expect(core.finishLineInput(), "42", "input prompt")
    }

    static func preserveWideCharacters() {
        let core = TermCore()
        core.putRaw("10 PRINT \"日本語\"\nOk\n")
        core.beginLineInput()
        core.setCursor(12, 0)
        expect(core.finishLineInput(), "10 PRINT \"日本語\"", "wide characters")
    }

    static func insertAndShiftText() {
        let core = TermCore()
        core.putRaw("10 PRNT \"HELLO\"\nOk\n")
        core.beginLineInput()
        core.setCursor(5, 0)
        _ = core.toggleInsertMode()
        core.putEditCharacter("I")
        expect(core.finishLineInput(), "10 PRINT \"HELLO\"", "insert and shift")
    }

    static func deleteAndCloseGap() {
        let core = TermCore()
        core.putRaw("10 PRXINT \"HELLO\"\nOk\n")
        core.beginLineInput()
        core.setCursor(5, 0)
        _ = core.toggleInsertMode()
        core.deleteEdit()
        expect(core.finishLineInput(), "10 PRINT \"HELLO\"", "delete and close gap")
    }

    static func backspaceAndCloseGap() {
        let core = TermCore()
        core.putRaw("10 PRIINT \"HELLO\"\nOk\n")
        core.beginLineInput()
        core.setCursor(7, 0)
        _ = core.toggleInsertMode()
        core.backspaceEdit()
        expect(core.finishLineInput(), "10 PRINT \"HELLO\"", "backspace and close gap")
    }

    static func insertAcrossWrappedLine() {
        let core = TermCore()
        let listed = String(repeating: "A", count: 79) + "B"
        core.putRaw(listed + "\nOk\n")
        core.beginLineInput()
        core.setCursor(79, 0)
        _ = core.toggleInsertMode()
        core.putEditCharacter("X")
        expect(core.finishLineInput(), String(repeating: "A", count: 79) + "XB",
               "insert across wrapped line")
    }

    static func insertWideCharacter() {
        let core = TermCore()
        core.putRaw("10 PRINT \"日本\"\nOk\n")
        core.beginLineInput()
        core.setCursor(14, 0)
        _ = core.toggleInsertMode()
        core.putEditCharacter("語")
        expect(core.finishLineInput(), "10 PRINT \"日本語\"", "insert wide character")
    }

    static func switchScreenWidth() {
        let core = TermCore()
        let console = TerminalConsole(core: core)
        let interpreter = Interpreter(console: console)
        interpreter.handleImmediate("SPEED 0")

        interpreter.handleImmediate("PSET (639,199),7")
        interpreter.handleImmediate("WIDTH 40")
        guard core.columns == 40, console.width == 40,
              console.graphicsWidth == 320,
              core.sync({ core.grid.allSatisfy { $0.count == 40 } &&
                          core.graphics.pixels.count == 320 * 200 }),
              core.point(639, 199) == -1 else {
            fatalError("WIDTH 40 did not create 40x25 text and 320x200 graphics")
        }
        interpreter.handleImmediate("PSET (319,199),6")
        guard core.point(319, 199) == 6 else { fatalError("320x200 edge pixel failed") }
        interpreter.handleImmediate("CIRCLE (100,100),10,2")
        guard core.point(100, 92) == 2 else {
            fatalError("WIDTH 40 did not select the 320x200 circle aspect")
        }

        interpreter.handleImmediate("WIDTH 20")
        guard core.columns == 40, console.graphicsWidth == 320 else {
            fatalError("invalid WIDTH changed the screen")
        }

        interpreter.handleImmediate("WIDTH 80")
        guard core.columns == 80, console.width == 80,
              console.graphicsWidth == 640,
              core.sync({ core.grid.allSatisfy { $0.count == 80 } &&
                          core.graphics.pixels.count == 640 * 200 }),
              core.point(319, 199) == 0 else {
            fatalError("WIDTH 80 did not restore 80x25 text and 640x200 graphics")
        }
    }

    static func editWrappedLineAt40Columns() {
        let core = TermCore()
        core.setColumns(40)
        let listed = String(repeating: "A", count: 39) + "B"
        core.putRaw(listed + "\nOk\n")
        core.beginLineInput()
        core.setCursor(39, 0)
        _ = core.toggleInsertMode()
        core.putEditCharacter("X")
        expect(core.finishLineInput(), String(repeating: "A", count: 39) + "XB",
               "40-column wrapped line")
    }

    static func keepWindowSizeAcrossWidths() {
        let core80 = TermCore()
        let size80 = TerminalView(core: core80).desiredSize
        let core40 = TermCore()
        core40.setColumns(40)
        let size40 = TerminalView(core: core40).desiredSize
        guard abs(size80.width - size40.width) < 0.01,
              abs(size80.height - size40.height) < 0.01 else {
            fatalError("WIDTH changed the window size: 80=\(size80), 40=\(size40)")
        }
        guard size80.height > 300 else {
            fatalError("terminal font metrics collapsed: \(size80)")
        }
    }

    static func showCursorOnlyDuringLineInput() {
        let core = TermCore()

        guard core.sync({ !core.cursorVisibleWhileLocked }) else {
            fatalError("cursor was visible while a BASIC program was running")
        }

        core.beginLineInput()
        guard core.sync({ core.cursorVisibleWhileLocked }) else {
            fatalError("cursor was hidden during line input")
        }

        _ = core.finishLineInput()
        guard core.sync({ !core.cursorVisibleWhileLocked }) else {
            fatalError("cursor remained visible after line input")
        }
    }

    static func changeBackgroundColor() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))

        guard core.sync({ core.bg == 0 }) else {
            fatalError("default background is not black")
        }

        interpreter.handleImmediate("COLOR 6,2")
        guard core.sync({ core.fg == 6 && core.bg == 2 }) else {
            fatalError("COLOR did not update foreground and background")
        }

        interpreter.handleImmediate("COLOR 5")
        guard core.sync({ core.fg == 5 && core.bg == 2 }) else {
            fatalError("COLOR without background did not preserve it")
        }
    }

    static func drawGraphicsPrimitives() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.handleImmediate("SPEED 0")

        interpreter.handleImmediate("PSET (10,20),2")
        interpreter.handleImmediate("PSET STEP (2,3),4")
        guard core.point(10, 20) == 2, core.point(12, 23) == 4 else {
            fatalError("PSET/STEP did not draw expected pixels")
        }

        interpreter.handleImmediate("LINE (20,20)-(30,30),3")
        guard core.point(20, 20) == 3, core.point(25, 25) == 3,
              core.point(30, 30) == 3 else { fatalError("LINE did not draw") }

        interpreter.handleImmediate("LINE (40,40)-(50,50),5,BF")
        guard core.point(45, 45) == 5 else { fatalError("LINE BF did not fill") }

        interpreter.handleImmediate("LINE (60,60)-(80,80),6,B")
        interpreter.handleImmediate("PAINT (70,70),1,6")
        guard core.point(60, 60) == 6, core.point(70, 70) == 1 else {
            fatalError("LINE B/PAINT did not draw")
        }

        interpreter.handleImmediate("CIRCLE (100,100),10,7")
        guard core.point(110, 100) == 7, core.point(100, 96) == 7 else {
            fatalError("CIRCLE did not draw")
        }

        interpreter.handleImmediate("IF POINT(10,20)=2 THEN PSET (1,1),7")
        guard core.point(1, 1) == 7 else { fatalError("POINT did not return pixel colour") }
        interpreter.handleImmediate("PRESET (1,1)")
        guard core.point(1, 1) == 0 else { fatalError("PRESET did not erase pixel") }
    }

    static func convertHexCharacterStrings() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.handleImmediate("SPEED 0")

        interpreter.handleImmediate("IF ASC(HEXCHR$(\"ff\"))=255 THEN PSET (1,1),7")
        interpreter.handleImmediate("IF ASC(MID$(HEXCHR$(\"80 40 20\"),2,1))=64 THEN PSET (2,1),7")
        guard core.point(1, 1) == 7, core.point(2, 1) == 7 else {
            fatalError("HEXCHR$ did not convert spaced hexadecimal byte pairs")
        }

        interpreter.handleImmediate("PRINT HEXCHR$(\"123\")")
        guard core.screenText.contains("Illegal function call") else {
            fatalError("HEXCHR$ accepted an incomplete byte")
        }
    }

    static func drawHuBasicTilePatterns() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.handleImmediate("SPEED 0")

        // One Hu-BASIC tile row: blue AA, red CC, green 33. The three
        // bitplanes combine into magenta, red, cyan, green and repeat.
        interpreter.handleImmediate("LINE (1,1)-(8,2),HEXCHR$(\"AA CC 33\"),BF")
        let expected = [2, 5, 4, 3, 2, 5, 4, 3]
        for (offset, color) in expected.enumerated() {
            guard core.point(offset + 1, 1) == color,
                  core.point(offset + 1, 2) == color else {
                fatalError("LINE BF tile pattern was not anchored to the screen")
            }
        }

        // Three all-set planes produce blue, red, green rows. PAINT must
        // discover the region before drawing because tile colours can differ
        // from the original interior colour.
        interpreter.handleImmediate("LINE (16,12)-(31,20),7,B")
        interpreter.handleImmediate("LINE (17,13)-(30,19),6,BF")
        interpreter.handleImmediate("PAINT (20,15),HEXCHR$(\"FF0000 00FF00 0000FF\"),7")
        guard core.point(16, 15) == 7,
              core.point(20, 15) == 1,
              core.point(20, 16) == 2,
              core.point(20, 17) == 4,
              core.point(20, 18) == 1 else {
            fatalError("PAINT did not apply the Hu-BASIC multi-row tile")
        }

        let untouched = core.point(40, 40)
        interpreter.handleImmediate("LINE (40,40)-(42,42),HEXCHR$(\"FF\"),BF")
        guard core.point(40, 40) == untouched,
              core.screenText.contains("Illegal function call") else {
            fatalError("LINE BF accepted tile data that was not B/R/G triples")
        }
    }

    static func paintUsesHorizontalScanLines() {
        let top = Set((1...7).map { 1 * 9 + $0 })
        let bottom = Set((1...7).map { 5 * 9 + $0 })
        let sides = Set((1...5).flatMap { y in [y * 9 + 1, y * 9 + 7] })
        let border = top.union(bottom).union(sides)

        let region = Interpreter.horizontalPaintRegion(
            from: (4, 3), width: 9, height: 7
        ) { x, y in
            border.contains(y * 9 + x)
        }

        let expectedRows = [3, 4, 2]
        guard region.count == 15 else {
            fatalError("PAINT horizontal scan omitted or duplicated pixels")
        }
        for (rowOffset, y) in expectedRows.enumerated() {
            let span = Array(region[(rowOffset * 5)..<(rowOffset * 5 + 5)])
            guard span.map({ $0.0 }) == [2, 3, 4, 5, 6],
                  span.allSatisfy({ $0.1 == y }) else {
                fatalError("PAINT did not discover its region as horizontal scan lines")
            }
        }
    }

    static func clearTextAndGraphicsSeparately() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.handleImmediate("SPEED 0")
        core.putRaw("TEXT")
        interpreter.handleImmediate("PSET (1,1),7")

        interpreter.handleImmediate("CLS 1")
        guard core.point(1, 1) == 7 else { fatalError("CLS 1 cleared graphics") }

        core.putRaw("TEXT")
        interpreter.handleImmediate("CLS 2")
        guard core.point(1, 1) == 0,
              core.sync({ core.grid[0][0].ch == "T" }) else {
            fatalError("CLS 2 did not preserve text and clear graphics")
        }
    }

    static func renderGraphicsLayer() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.handleImmediate("SPEED 0")
        interpreter.handleImmediate("WIDTH 40")
        interpreter.handleImmediate("LINE (50,80)-(270,120),2,BF")
        let view = TerminalView(core: core)
        view.frame = NSRect(origin: .zero, size: view.desiredSize)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("could not create graphics render target")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.bitmapData else { fatalError("graphics render has no pixels") }
        let count = bitmap.bytesPerRow * bitmap.pixelsHigh
        var foundRed = false
        for offset in stride(from: 0, to: count - 3, by: 4) {
            if data[offset] > 220, data[offset + 1] > 45, data[offset + 1] < 140,
               data[offset + 2] > 45, data[offset + 2] < 140 {
                foundRed = true
                break
            }
        }
        guard foundRed else { fatalError("graphics plane was not composited into the view") }
    }

    static func persistCRTEffectSetting() {
        let suiteName = "local.retrobasic.tests.crt-effect"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create isolated CRT effect preferences")
        }
        preferences.removePersistentDomain(forName: suiteName)

        let firstView = TerminalView(core: TermCore(), preferences: preferences)
        guard !firstView.isCRTEffectEnabled else {
            fatalError("CRT effect was not off by default")
        }
        firstView.toggleCRTEffect(nil)
        guard firstView.isCRTEffectEnabled else {
            fatalError("CRT effect did not turn on")
        }

        let restoredView = TerminalView(core: TermCore(), preferences: preferences)
        guard restoredView.isCRTEffectEnabled else {
            fatalError("CRT effect setting was not restored")
        }
        restoredView.toggleCRTEffect(nil)
        guard !restoredView.isCRTEffectEnabled else {
            fatalError("CRT effect did not turn off")
        }
        preferences.removePersistentDomain(forName: suiteName)
    }

    static func rejectRemovedScreenCommand() {
        let core = TermCore()
        Interpreter(console: TerminalConsole(core: core)).handleImmediate("SCREEN 0")
        guard core.screenText.contains("Syntax error") else {
            fatalError("removed SCREEN command was still accepted")
        }
    }

    static func renumberProgramAndReferences() {
        let interpreter = Interpreter(console: TerminalConsole(core: TermCore()))
        interpreter.processInput("100 GOTO 300")
        interpreter.processInput("200 PRINT \"GOTO 300\":REM GOTO 300")
        interpreter.processInput("300 IF A THEN 100 ELSE 200")
        interpreter.processInput("400 ON A GOSUB 100,300:RESTORE 300")
        interpreter.processInput("500 DATA 100,200,300")
        interpreter.processInput("600 RUN 300")
        interpreter.handleImmediate("RENUM 1000,200,20")

        let actual = interpreter.program.map { "\($0.num) \(String($0.text))" }.joined(separator: "\n")
        let expected = """
        100 GOTO 1020
        1000 PRINT "GOTO 300":REM GOTO 300
        1020 IF A THEN 100 ELSE 1000
        1040 ON A GOSUB 100,1020:RESTORE 1020
        1060 DATA 100,200,300
        1080 RUN 1020
        """
        expect(actual, expected, "RENUM program and references")
    }

    static func renumberWithDefaults() {
        let interpreter = Interpreter(console: TerminalConsole(core: TermCore()))
        interpreter.processInput("100 PRINT 100")
        interpreter.processInput("200 GOTO 100")
        interpreter.handleImmediate("RENUM")
        interpreter.handleImmediate("RENUM 100,,5")

        let actual = interpreter.program.map { "\($0.num) \(String($0.text))" }.joined(separator: "\n")
        expect(actual, "100 PRINT 100\n105 GOTO 100", "RENUM defaults")
    }

    static func rejectInvalidRenumbering() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.processInput("10 PRINT 1")
        interpreter.processInput("20 GOTO 10")
        interpreter.handleImmediate("RENUM 10,20,10")
        guard core.screenText.contains("Illegal function call"),
              interpreter.program.map(\.num) == [10, 20] else {
            fatalError("RENUM accepted a line-number collision")
        }

        interpreter.handleImmediate("RENUM 65520,,10")
        guard interpreter.program.map(\.num) == [10, 20] else {
            fatalError("RENUM accepted a line number above 65529")
        }
    }

    static func executeRenumberedProgram() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.processInput("100 PRINT \"FIRST\":GOTO 300")
        interpreter.processInput("200 PRINT \"WRONG\":END")
        interpreter.processInput("300 PRINT \"LAST\":END")
        interpreter.handleImmediate("RENUM 1000")
        interpreter.handleImmediate("RUN")
        guard core.screenText.contains("FIRST\nLAST\n"),
              !core.screenText.contains("WRONG") else {
            fatalError("renumbered program did not execute updated targets")
        }
    }

    static func generateAutomaticLineNumbers() {
        let interpreter = Interpreter(console: TerminalConsole(core: TermCore()))
        guard !interpreter.processInput("AUTO 100,20"),
              !interpreter.processInput("print 1"),
              !interpreter.processInput("goto 100") else {
            fatalError("AUTO unexpectedly returned to the command prompt")
        }

        let actual = interpreter.program.map { "\($0.num) \(String($0.text))" }
            .joined(separator: "\n")
        expect(actual, "100 PRINT 1\n120 GOTO 100", "AUTO line generation")
    }

    static func preserveExistingLinesDuringAuto() {
        let interpreter = Interpreter(console: TerminalConsole(core: TermCore()))
        interpreter.processInput("10 PRINT \"KEEP\"")
        interpreter.processInput("AUTO")
        interpreter.processInput("")
        interpreter.processInput("PRINT \"NEW\"")

        let actual = interpreter.program.map { "\($0.num) \(String($0.text))" }
            .joined(separator: "\n")
        expect(actual, "10 PRINT \"KEEP\"\n20 PRINT \"NEW\"",
               "AUTO blank line preservation")
    }

    static func reuseAutomaticLineIncrement() {
        let interpreter = Interpreter(console: TerminalConsole(core: TermCore()))
        interpreter.handleImmediate("AUTO 100,25")
        interpreter.handleImmediate("AUTO 200,")
        interpreter.processInput("PRINT 1")
        interpreter.processInput("PRINT 2")

        guard interpreter.program.map(\.num) == [200, 225] else {
            fatalError("AUTO did not reuse the previous increment")
        }
    }

    static func rejectInvalidAutoArguments() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        guard interpreter.processInput("AUTO 10,0"),
              interpreter.processInput("AUTO 65530,10"),
              core.screenText.components(separatedBy: "Illegal function call").count == 3 else {
            fatalError("AUTO accepted invalid arguments")
        }
    }

    static func rejectAutoInsideProgram() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.processInput("10 AUTO")
        interpreter.handleImmediate("RUN")
        guard core.screenText.contains("Illegal direct in 10") else {
            fatalError("AUTO was accepted inside a program")
        }
    }

    static func rejectUnsafeDimensions() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.handleImmediate("DIM A(-2)")
        guard core.screenText.contains("Subscript out of range") else {
            fatalError("DIM accepted a negative upper bound")
        }

        interpreter.handleImmediate("DIM B(2147483647,2147483647,2147483647)")
        guard core.screenText.contains("Out of memory") else {
            fatalError("DIM accepted an unsafe allocation size")
        }
    }

    static func rejectOversizedLineNumbers() {
        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.handleImmediate("GOTO " + String(repeating: "9", count: 1_000))
        guard core.screenText.contains("Overflow") else {
            fatalError("oversized line number did not produce a BASIC error")
        }
    }

    static func rejectDirectStatementsDuringMerge() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetroBASIC-merge-\(UUID().uuidString)")
        setenv("RETROBASIC_DIR", directory.path, 1)
        defer {
            unsetenv("RETROBASIC_DIR")
            try? FileManager.default.removeItem(at: directory)
        }

        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try "10 PRINT \"SHOULD NOT MERGE\"\nNEW\n".write(
                to: directory.appendingPathComponent("UNSAFE.bas"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            fatalError("could not create MERGE fixture: \(error)")
        }

        let core = TermCore()
        let interpreter = Interpreter(console: TerminalConsole(core: core))
        interpreter.processInput("100 PRINT \"KEEP\"")
        interpreter.handleImmediate("MERGE \"UNSAFE\"")
        guard core.screenText.contains("Direct statement in file"),
              interpreter.program.map(\.num) == [100] else {
            fatalError("MERGE executed or partially applied a direct statement")
        }
    }
}
