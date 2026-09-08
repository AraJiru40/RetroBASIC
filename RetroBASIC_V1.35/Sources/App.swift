import Cocoa
import Carbon

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var window: NSWindow!
    private var termView: TerminalView!
    private var characterPalette: CharacterPaletteController!
    private let core = TermCore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        termView = TerminalView(core: core)
        characterPalette = CharacterPaletteController(terminalView: termView)
        let size = termView.desiredSize

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "RetroBASIC"
        window.contentView = termView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(termView)
        NSApp.activate(ignoringOtherApps: true)
        selectASCIIInputSource()

        let console = TerminalConsole(core: core)
        let interp = Interpreter(console: console)
        let thread = Thread { interp.repl() }
        thread.name = "BASIC"
        thread.stackSize = 4 << 20
        thread.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// BASIC commands are ASCII-oriented. Start with the user's most recently
    /// used ASCII-capable keyboard source even if a Japanese IME was active
    /// before launch. The user can switch the IME back on normally afterwards.
    private func selectASCIIInputSource() {
        termView.inputContext?.discardMarkedText()
        let source = TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()
        _ = TISSelectInputSource(source)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About RetroBASIC",
                        action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit RetroBASIC",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy Screen",
                         action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        let insertItem = editMenu.addItem(withTitle: "Insert Mode",
                                          action: #selector(TerminalView.toggleInsertMode(_:)),
                                          keyEquivalent: "i")
        insertItem.keyEquivalentModifierMask = [.control]

        // Input menu
        let inputItem = NSMenuItem()
        mainMenu.addItem(inputItem)
        let inputMenu = NSMenu(title: "Input")
        inputItem.submenu = inputMenu
        let paletteItem = inputMenu.addItem(withTitle: "Character Palette…",
                                            action: #selector(showCharacterPalette(_:)),
                                            keyEquivalent: "k")
        paletteItem.target = self

        // Run menu
        let runItem = NSMenuItem()
        mainMenu.addItem(runItem)
        let runMenu = NSMenu(title: "Run")
        runItem.submenu = runMenu
        runMenu.addItem(withTitle: "Break (Stop Program)",
                        action: #selector(TerminalView.sendBreak(_:)), keyEquivalent: ".")

        // View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Zoom In",
                         action: #selector(TerminalView.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out",
                         action: #selector(TerminalView.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "CRT Effect",
                         action: #selector(TerminalView.toggleCRTEffect(_:)), keyEquivalent: "")

        NSApp.mainMenu = mainMenu
    }

    @objc private func showCharacterPalette(_ sender: Any?) {
        characterPalette.showPalette()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "RetroBASIC 1.35"
        alert.informativeText = """
            1983年ごろのMicrosoft系BASICインタプリタ風の環境です。
            行番号付きでプログラムを入力し、RUN で実行します。

            例:
              10 PRINT "HELLO"
              20 GOTO 10
              RUN
            (Ctrl+C または Cmd+. で中断)

            WIDTH 40 / WIDTH 80 で画面桁数を切り替えます。

            SAVE/LOAD先: ~/Documents/RetroBASIC/
            """
        alert.runModal()
    }
}
