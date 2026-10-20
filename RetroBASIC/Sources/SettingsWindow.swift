import Cocoa

/// Settings window (Cmd+,). Holds the folder used by SAVE / LOAD / MERGE /
/// FILES / KILL; the interpreter reads the choice from UserDefaults on each use.
final class SettingsWindowController: NSWindowController {
    private let preferences: UserDefaults
    private let pathField = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let defaultButton = NSButton(title: "Use Default", target: nil, action: nil)

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 132),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "RetroBASIC Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContent()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func showSettings() {
        refresh()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Save Folder (SAVE / LOAD / MERGE / FILES / KILL)")
        title.font = .boldSystemFont(ofSize: 12)
        title.frame = NSRect(x: 16, y: 100, width: 488, height: 18)
        content.addSubview(title)

        pathField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.isSelectable = true
        pathField.frame = NSRect(x: 16, y: 76, width: 488, height: 18)
        content.addSubview(pathField)

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 16, y: 54, width: 488, height: 18)
        content.addSubview(note)

        let reveal = NSButton(title: "Show in Finder", target: self,
                              action: #selector(revealFolder(_:)))
        reveal.frame = NSRect(x: 12, y: 12, width: 130, height: 32)
        content.addSubview(reveal)

        defaultButton.target = self
        defaultButton.action = #selector(useDefault(_:))
        defaultButton.frame = NSRect(x: 266, y: 12, width: 120, height: 32)
        content.addSubview(defaultButton)

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder(_:)))
        choose.keyEquivalent = "\r"
        choose.frame = NSRect(x: 390, y: 12, width: 118, height: 32)
        content.addSubview(choose)
    }

    private var hasCustomFolder: Bool {
        !(preferences.string(forKey: Interpreter.saveDirectoryDefaultsKey) ?? "").isEmpty
    }

    private func refresh() {
        let folder = Interpreter.saveDirectory(preferences: preferences)
        pathField.stringValue = (folder.path as NSString).abbreviatingWithTildeInPath
        defaultButton.isEnabled = hasCustomFolder
        if ProcessInfo.processInfo.environment["RETROBASIC_DIR"] != nil {
            note.stringValue = "RETROBASIC_DIR is set, so it overrides this setting."
        } else if hasCustomFolder {
            note.stringValue = "Default: " + (Interpreter.defaultSaveDirectory.path as NSString)
                .abbreviatingWithTildeInPath
        } else {
            note.stringValue = "Using the default folder. It is created on the first SAVE."
        }
        note.font = .systemFont(ofSize: 11)
    }

    @objc private func chooseFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder for SAVE / LOAD / FILES"
        let current = Interpreter.saveDirectory(preferences: preferences)
        if FileManager.default.fileExists(atPath: current.path) { panel.directoryURL = current }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.preferences.set(url.path, forKey: Interpreter.saveDirectoryDefaultsKey)
            self.refresh()
        }
    }

    @objc private func useDefault(_ sender: Any?) {
        preferences.removeObject(forKey: Interpreter.saveDirectoryDefaultsKey)
        refresh()
    }

    @objc private func revealFolder(_ sender: Any?) {
        let folder = Interpreter.saveDirectory(preferences: preferences)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
