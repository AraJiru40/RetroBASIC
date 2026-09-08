import Cocoa

/// A modeless picker that shows the actual 8x8 RetroBASIC glyphs. Characters
/// are composed in the palette and sent to BASIC together when GO is pressed.
final class CharacterPaletteController: NSWindowController {
    private weak var terminalView: TerminalView?
    private let grid = CharacterGridView()
    private let composition = CharacterCompositionView()
    private let selector = NSSegmentedControl(labels: ["Katakana", "GRPH"],
                                               trackingMode: .selectOne,
                                               target: nil, action: nil)
    private let status = NSTextField(labelWithString: "A1  ｡")
    private(set) var bufferedCodes: [UInt8] = [] {
        didSet { composition.codes = bufferedCodes }
    }

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "RetroBASIC Character Palette"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        configureContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureContent() {
        guard let content = window?.contentView else { return }

        selector.selectedSegment = 0
        selector.target = self
        selector.action = #selector(changeSet(_:))
        selector.frame = NSRect(x: 8, y: 226, width: 210, height: 26)
        content.addSubview(selector)

        let hint = NSTextField(labelWithString: "Build text below, then press GO")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .right
        hint.frame = NSRect(x: 225, y: 231, width: 287, height: 18)
        content.addSubview(hint)

        grid.frame = NSRect(x: 4, y: 94, width: 512, height: 128)
        grid.codes = RetroCharset.kanaCodes
        grid.onSelect = { [weak self] code in self?.appendCharacter(code) }
        content.addSubview(grid)

        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 8, y: 72, width: 504, height: 18)
        content.addSubview(status)

        let compositionBar = PaletteBarBackgroundView(
            frame: NSRect(x: 8, y: 8, width: 504, height: 56))
        content.addSubview(compositionBar)

        composition.frame = NSRect(x: 8, y: 8, width: 378, height: 56)
        content.addSubview(composition)

        let backspace = NSButton(title: "←", target: self,
                                 action: #selector(deleteLastCharacter(_:)))
        backspace.font = .systemFont(ofSize: 24, weight: .regular)
        backspace.bezelStyle = .texturedSquare
        backspace.frame = NSRect(x: 394, y: 17, width: 54, height: 38)
        backspace.toolTip = "Delete the last character"
        content.addSubview(backspace)

        let go = NSButton(title: "GO", target: self, action: #selector(commitComposition(_:)))
        go.font = .monospacedSystemFont(ofSize: 19, weight: .regular)
        go.bezelStyle = .texturedSquare
        go.frame = NSRect(x: 456, y: 17, width: 56, height: 38)
        go.toolTip = "Insert the composed text into BASIC"
        content.addSubview(go)
    }

    func showPalette() {
        showWindow(nil)
        window?.center()
        window?.orderFront(nil)
    }

    @objc private func changeSet(_ sender: NSSegmentedControl) {
        grid.codes = sender.selectedSegment == 0
            ? RetroCharset.kanaCodes : RetroCharset.graphicCodes
        if let first = grid.codes.first { updateStatus(first) }
    }

    func appendCharacter(_ code: UInt8) {
        bufferedCodes.append(code)
        updateStatus(code)
    }

    @objc private func deleteLastCharacter(_ sender: Any?) {
        guard !bufferedCodes.isEmpty else { return }
        bufferedCodes.removeLast()
        if let code = bufferedCodes.last {
            updateStatus(code)
        } else {
            status.stringValue = "Select characters to compose"
        }
    }

    @objc private func commitComposition(_ sender: Any?) {
        commitBufferedCharacters()
    }

    func commitBufferedCharacters() {
        guard !bufferedCodes.isEmpty else { return }
        for code in bufferedCodes {
            terminalView?.core.pushKey(RetroCharset.character(forByte: code))
        }
        bufferedCodes.removeAll(keepingCapacity: true)
        terminalView?.window?.makeKey()
        terminalView?.window?.makeFirstResponder(terminalView)
    }

    func removeLastBufferedCharacter() {
        deleteLastCharacter(nil)
    }

    private func updateStatus(_ code: UInt8) {
        let character = RetroCharset.displayCharacter(forByte: code)
        status.stringValue = String(format: "%02X  %@", code, String(character))
    }
}

private final class PaletteBarBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.005, green: 0.012, blue: 0.025, alpha: 1).setFill()
        bounds.fill()
    }
}

private final class CharacterCompositionView: NSView {
    private static let slotWidth: CGFloat = 24
    private static let glyphScale: CGFloat = 2

    var codes: [UInt8] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.005, green: 0.012, blue: 0.025, alpha: 1).setFill()
        bounds.fill()

        let visibleCount = max(1, Int((bounds.width - 16) / Self.slotWidth))
        let visibleCodes = codes.suffix(visibleCount)
        for (index, code) in visibleCodes.enumerated() {
            guard let rows = RetroFont.glyph(forByte: code) else { continue }
            let originX = CGFloat(index) * Self.slotWidth + 8
            let originY: CGFloat = 18
            NSColor(calibratedRed: 0.20, green: 1.0, blue: 0.55, alpha: 1).setFill()
            for (dy, bits) in rows.enumerated() {
                for dx in 0..<8 where bits & (0x80 >> UInt8(dx)) != 0 {
                    NSRect(x: originX + CGFloat(dx) * Self.glyphScale,
                           y: originY + CGFloat(dy) * Self.glyphScale,
                           width: Self.glyphScale, height: Self.glyphScale).fill()
                }
            }
        }
    }
}

private final class CharacterGridView: NSView {
    private static let columns = 16
    private static let cellWidth: CGFloat = 32
    private static let cellHeight: CGFloat = 32
    private static let glyphScale: CGFloat = 2

    var codes: [UInt8] = [] {
        didSet { selectedIndex = nil; needsDisplay = true }
    }
    var onSelect: ((UInt8) -> Void)?
    private var selectedIndex: Int?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.015, green: 0.025, blue: 0.055, alpha: 1).setFill()
        bounds.fill()

        let codeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.66, alpha: 1),
        ]

        for (index, code) in codes.enumerated() {
            let column = index % Self.columns
            let row = index / Self.columns
            let rect = NSRect(x: CGFloat(column) * Self.cellWidth,
                              y: CGFloat(row) * Self.cellHeight,
                              width: Self.cellWidth, height: Self.cellHeight)
            guard rect.intersects(dirtyRect) else { continue }

            if selectedIndex == index {
                NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.40, alpha: 1).setFill()
                rect.insetBy(dx: 1, dy: 1).fill()
            }
            NSColor(calibratedWhite: 0.20, alpha: 1).setStroke()
            NSBezierPath(rect: rect).stroke()

            if let rows = RetroFont.glyph(forByte: code) {
                NSColor(calibratedRed: 0.20, green: 1.0, blue: 0.55, alpha: 1).setFill()
                let originX = rect.minX + 8
                let originY = rect.minY + 3
                for (dy, bits) in rows.enumerated() {
                    for dx in 0..<8 where bits & (0x80 >> UInt8(dx)) != 0 {
                        NSRect(x: originX + CGFloat(dx) * Self.glyphScale,
                               y: originY + CGFloat(dy) * Self.glyphScale,
                               width: Self.glyphScale, height: Self.glyphScale).fill()
                    }
                }
            }

            NSString(format: "%02X", code).draw(at: NSPoint(x: rect.minX + 8,
                                                             y: rect.minY + 21),
                                                  withAttributes: codeAttributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = Int(point.x / Self.cellWidth)
        let row = Int(point.y / Self.cellHeight)
        guard column >= 0, column < Self.columns, row >= 0 else { return }
        let index = row * Self.columns + column
        guard codes.indices.contains(index) else { return }
        selectedIndex = index
        needsDisplay = true
        onSelect?(codes[index])
    }
}
