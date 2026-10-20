import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ConverterPalette {
    static let background = Color(red: 0.018, green: 0.023, blue: 0.035)
    static let panel = Color(red: 0.052, green: 0.061, blue: 0.082)
    static let accent = Color(red: 0.18, green: 0.64, blue: 1.0)
    static let secondaryAccent = Color(red: 0.56, green: 0.34, blue: 1.0)
}

@MainActor
final class MIDIToMMLModel: ObservableObject {
    @Published private(set) var midiFile: MIDIFile?
    @Published private(set) var sourceURL: URL?
    @Published var partIDs: [String?] = [nil, nil, nil]
    @Published var quantization: MMLQuantization = .sixteenth
    @Published var backgroundPlayback = false
    @Published var preserveVelocity = true
    @Published var output = ""
    @Published private(set) var warnings: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var copied = false
    @Published var isDropTarget = false

    var parts: [MIDIPart] { midiFile?.parts ?? [] }
    var canExport: Bool { midiFile != nil && !output.isEmpty && errorMessage == nil }

    var fileSummary: String {
        guard let file = midiFile else { return "MIDIファイルを開くか、このウインドウへドロップしてください。" }
        return "FORMAT \(file.format)  ·  \(file.trackCount) TRACKS  ·  \(file.parts.count) PARTS  ·  TPQN \(file.ticksPerQuarter)"
    }

    func chooseMIDI() {
        let panel = NSOpenPanel()
        panel.title = "MIDIファイルを選択"
        panel.prompt = "変換"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.midiTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    func load(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            try load(data: data, fileName: url.lastPathComponent)
            sourceURL = url
        } catch {
            midiFile = nil
            sourceURL = nil
            output = ""
            warnings = []
            errorMessage = error.localizedDescription
        }
    }

    func load(data: Data, fileName: String) throws {
        let parsed = try MIDIFileParser.parse(data, fileName: fileName)
        midiFile = parsed
        sourceURL = nil
        partIDs = RetroBASICMMLConverter.suggestedPartIDs(for: parsed)
        errorMessage = nil
        regenerate()
    }

    func setPart(_ id: String?, for channel: Int) {
        guard partIDs.indices.contains(channel) else { return }
        partIDs[channel] = id
        regenerate()
    }

    func setQuantization(_ value: MMLQuantization) {
        quantization = value
        regenerate()
    }

    func setBackgroundPlayback(_ value: Bool) {
        backgroundPlayback = value
        regenerate()
    }

    func setPreserveVelocity(_ value: Bool) {
        preserveVelocity = value
        regenerate()
    }

    func regenerate() {
        guard let file = midiFile else { return }
        do {
            let result = try RetroBASICMMLConverter.convert(
                file,
                options: MIDIConversionOptions(
                    partIDs: partIDs,
                    quantization: quantization,
                    backgroundPlayback: backgroundPlayback,
                    preserveVelocity: preserveVelocity
                )
            )
            output = result.program
            warnings = result.warnings + [
                String(format: "量子化後の演奏時間: 約%.1f秒", result.approximateDuration)
            ]
            errorMessage = nil
        } catch {
            output = ""
            warnings = []
            errorMessage = error.localizedDescription
        }
    }

    func copyOutput(to pasteboard: NSPasteboard = .general) {
        copyOutput { text in
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
    }

    func copyOutput(using writer: (String) -> Bool) {
        guard canExport, writer(output) else {
            copied = false
            return
        }
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copied = false
        }
    }

    func saveBASIC() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.title = "RetroBASICプログラムを保存"
        panel.prompt = "保存"
        panel.allowedContentTypes = [UTType(filenameExtension: "bas") ?? .plainText]
        let fallbackBase = midiFile.map {
            URL(fileURLWithPath: $0.fileName).deletingPathExtension().lastPathComponent
        }
        let base = sourceURL?.deletingPathExtension().lastPathComponent
            ?? fallbackBase
            ?? "MIDI_MUSIC"
        panel.nameFieldStringValue = base + ".bas"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                          options: nil) { [weak self] item, _ in
            let url: URL?
            if let value = item as? URL {
                url = value
            } else if let value = item as? Data {
                url = URL(dataRepresentation: value, relativeTo: nil)
            } else {
                url = nil
            }
            guard let url else { return }
            DispatchQueue.main.async { self?.load(url: url) }
        }
        return true
    }

    private static var midiTypes: [UTType] {
        [.midi]
    }
}

private struct ConverterCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(ConverterPalette.panel)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.09), lineWidth: 1)
                    }
            }
    }
}

private struct PartAssignmentRow: View {
    @ObservedObject var model: MIDIToMMLModel
    let channel: Int

    private var letter: String { ["A", "B", "C"][channel] }

    var body: some View {
        HStack(spacing: 12) {
            Text(letter)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(channel == 0 ? ConverterPalette.accent : ConverterPalette.secondaryAccent)
                }

            Picker("PSG \(letter)", selection: Binding(
                get: { model.partIDs[channel] },
                set: { model.setPart($0, for: channel) }
            )) {
                Text("— 使用しない —").tag(Optional<String>.none)
                ForEach(model.parts) { part in
                    Text(part.displayName).tag(Optional(part.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }
}

private struct SourcePanel: View {
    @ObservedObject var model: MIDIToMMLModel

    var body: some View {
        ConverterCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.midiFile?.fileName ?? "NO MIDI LOADED")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Text(model.fileSummary)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.chooseMIDI()
                    } label: {
                        Label("OPEN MIDI", systemImage: "music.note.list")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ConverterPalette.accent)
                }

                if model.midiFile == nil {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 28, weight: .light))
                            Text("DROP .MID / .MIDI HERE")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .tracking(1)
                        }
                        .foregroundStyle(model.isDropTarget ? ConverterPalette.accent : .secondary)
                        Spacer()
                    }
                    .frame(height: 74)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                            .foregroundStyle(model.isDropTarget
                                             ? ConverterPalette.accent
                                             : Color.white.opacity(0.18))
                    }
                }
            }
        }
    }
}

private struct SettingsPanel: View {
    @ObservedObject var model: MIDIToMMLModel

    var body: some View {
        ConverterCard {
            VStack(alignment: .leading, spacing: 16) {
                panelTitle("PSG CHANNEL ASSIGNMENT", icon: "slider.horizontal.3")
                ForEach(0..<3, id: \.self) { channel in
                    PartAssignmentRow(model: model, channel: channel)
                }

                Divider().overlay(.white.opacity(0.08))
                panelTitle("CONVERSION", icon: "dial.medium")

                HStack {
                    Text("QUANTIZE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Quantize", selection: Binding(
                        get: { model.quantization },
                        set: { model.setQuantization($0) }
                    )) {
                        ForEach(MMLQuantization.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }

                Toggle(isOn: Binding(
                    get: { model.backgroundPlayback },
                    set: { model.setBackgroundPlayback($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BACKGROUND PLAYBACK (MB)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                        Text("PLAYの直後からBASICプログラムを続行")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: Binding(
                    get: { model.preserveVelocity },
                    set: { model.setPreserveVelocity($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VELOCITY → VOLUME")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                        Text("MIDIベロシティをV1〜V15へ変換")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
        .disabled(model.midiFile == nil)
    }

    private func panelTitle(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.90))
    }
}

private struct OutputPanel: View {
    @ObservedObject var model: MIDIToMMLModel

    var body: some View {
        ConverterCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("RETROBASIC PROGRAM", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .tracking(1)
                    Spacer()
                    if let file = model.midiFile {
                        Text("\(file.notes.count) MIDI NOTES")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                TextEditor(text: $model.output)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(.black.opacity(0.34))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(.white.opacity(0.08), lineWidth: 1)
                            }
                    }
                    .overlay {
                        if model.output.isEmpty {
                            Text("変換されたBASICプログラムがここに表示されます")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                    }

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                } else if !model.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "info.circle")
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        model.copyOutput()
                    } label: {
                        Label(model.copied ? "COPIED" : "COPY BASIC",
                              systemImage: model.copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.copied ? .green : ConverterPalette.accent)
                    .keyboardShortcut("c", modifiers: [.command, .shift])

                    Button {
                        model.saveBASIC()
                    } label: {
                        Label("SAVE .BAS", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(!model.canExport)
            }
        }
    }
}

struct MIDIToMMLContentView: View {
    @StateObject private var model: MIDIToMMLModel

    @MainActor
    init() {
        _model = StateObject(wrappedValue: MIDIToMMLModel())
    }

    @MainActor
    init(model: MIDIToMMLModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    ConverterPalette.background,
                    Color(red: 0.030, green: 0.040, blue: 0.064),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(ConverterPalette.accent)
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.07)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MIDI TO RETROBASIC MML")
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .tracking(1.2)
                        Text("3-VOICE AY-3-8910 PROGRAM CONVERTER")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .tracking(1.5)
                    }
                    Spacer()
                    Text("LOAD  →  ASSIGN  →  COPY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        SourcePanel(model: model)
                        SettingsPanel(model: model)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 470)

                    OutputPanel(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(22)
        }
        .frame(minWidth: 1080, minHeight: 700)
        .preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL.identifier],
                isTargeted: $model.isDropTarget,
                perform: model.acceptDrop)
    }
}

final class MIDIToMMLAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.applicationIconImage = makeIcon()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func makeIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor(red: 0.025, green: 0.035, blue: 0.060, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                     xRadius: 106, yRadius: 106).fill()
        let text = "♫"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 300, weight: .bold),
            .foregroundColor: NSColor(red: 0.18, green: 0.64, blue: 1, alpha: 1),
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (size.width - textSize.width) / 2,
                              y: (size.height - textSize.height) / 2 - 12),
                  withAttributes: attributes)
        return image
    }
}

#if !SNAPSHOT
@main
struct MIDIToMMLApp: App {
    @NSApplicationDelegateAdaptor(MIDIToMMLAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("MIDI to RetroBASIC MML") {
            MIDIToMMLContentView()
        }
        .defaultSize(width: 1160, height: 760)
        .windowResizability(.contentMinSize)
    }
}
#endif
