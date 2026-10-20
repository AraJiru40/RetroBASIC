import AppKit
import SwiftUI

enum RetroPalette {
    static let names = ["Black", "Blue", "Red", "Magenta", "Green", "Cyan", "Yellow", "White"]

    static let colors: [Color] = [
        Color(red: 0.035, green: 0.040, blue: 0.055),
        Color(red: 0.18, green: 0.36, blue: 1.00),
        Color(red: 1.00, green: 0.28, blue: 0.32),
        Color(red: 1.00, green: 0.32, blue: 0.96),
        Color(red: 0.00, green: 0.92, blue: 0.34),
        Color(red: 0.00, green: 0.88, blue: 0.90),
        Color(red: 1.00, green: 0.95, blue: 0.12),
        Color(red: 0.96, green: 0.97, blue: 1.00),
    ]

    static let nsColors: [NSColor] = [
        NSColor(red: 0.035, green: 0.040, blue: 0.055, alpha: 1),
        NSColor(red: 0.18, green: 0.36, blue: 1.00, alpha: 1),
        NSColor(red: 1.00, green: 0.28, blue: 0.32, alpha: 1),
        NSColor(red: 1.00, green: 0.32, blue: 0.96, alpha: 1),
        NSColor(red: 0.00, green: 0.92, blue: 0.34, alpha: 1),
        NSColor(red: 0.00, green: 0.88, blue: 0.90, alpha: 1),
        NSColor(red: 1.00, green: 0.95, blue: 0.12, alpha: 1),
        NSColor(red: 0.96, green: 0.97, blue: 1.00, alpha: 1),
    ]
}

@MainActor
final class TilePatternModel: ObservableObject {
    @Published private(set) var tile = TilePatternData()
    @Published var selectedColor = 1
    @Published private(set) var copied = false
    private var copyGeneration = 0

    func paint(row: Int, column: Int) {
        var updated = tile
        updated.paint(row: row, column: column, color: selectedColor)
        tile = updated
    }

    func resizeRows(to rows: Int) {
        var updated = tile
        updated.resizeRows(to: rows)
        tile = updated
    }

    func clear() {
        var updated = tile
        updated.clear()
        tile = updated
    }

    func fill() {
        var updated = tile
        updated.fill(with: selectedColor)
        tile = updated
    }

    func checkerboard() {
        var updated = tile
        updated.makeCheckerboard(first: 1, second: 3)
        tile = updated
    }

    func copyExpression(to pasteboard: NSPasteboard = .general) {
        copyExpression { expression in
            pasteboard.clearContents()
            return pasteboard.setString(expression, forType: .string)
        }
    }

    func copyExpression(using writer: (String) -> Bool) {
        guard writer(tile.hexExpression) else {
            copied = false
            return
        }
        copied = true
        copyGeneration += 1
        let generation = copyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.copyGeneration == generation else { return }
            self.copied = false
        }
    }
}

struct PixelGrid: View {
    @ObservedObject var model: TilePatternModel
    @State private var lastPaintedIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let cellWidth = size.width / CGFloat(TilePatternData.width)
                let cellHeight = size.height / CGFloat(model.tile.rows)
                for row in 0..<model.tile.rows {
                    for column in 0..<TilePatternData.width {
                        let rect = CGRect(
                            x: CGFloat(column) * cellWidth,
                            y: CGFloat(row) * cellHeight,
                            width: cellWidth,
                            height: cellHeight
                        )
                        let color = RetroPalette.colors[model.tile[row, column]]
                        context.fill(Path(rect), with: .color(color))
                        context.stroke(Path(rect.insetBy(dx: 0.35, dy: 0.35)),
                                       with: .color(.white.opacity(0.16)), lineWidth: 0.7)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        paint(at: value.location, in: proxy.size)
                    }
                    .onEnded { _ in lastPaintedIndex = nil }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.white.opacity(0.92), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
        }
        .aspectRatio(CGFloat(TilePatternData.width) / CGFloat(model.tile.rows), contentMode: .fit)
        .accessibilityLabel("8 by \(model.tile.rows) tile editor")
        .accessibilityHint("Select a palette color, then click or drag to paint cells")
    }

    private func paint(at location: CGPoint, in size: CGSize) {
        guard location.x >= 0, location.y >= 0,
              location.x < size.width, location.y < size.height else { return }
        let column = min(TilePatternData.width - 1,
                         Int(location.x / (size.width / CGFloat(TilePatternData.width))))
        let row = min(model.tile.rows - 1,
                      Int(location.y / (size.height / CGFloat(model.tile.rows))))
        let index = row * TilePatternData.width + column
        guard index != lastPaintedIndex else { return }
        lastPaintedIndex = index
        model.paint(row: row, column: column)
    }
}

struct AppCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(red: 0.055, green: 0.063, blue: 0.082))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    }
            }
    }
}

struct UtilityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.65 : 0.90))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.07 : 0.11))
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct CopyButtonStyle: ButtonStyle {
    let copied: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(copied ? Color.green : Color(red: 0.16, green: 0.38, blue: 1.0))
            }
            .shadow(color: (copied ? Color.green : Color.blue).opacity(0.28), radius: 12, y: 5)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct EditorPanel: View {
    @ObservedObject var model: TilePatternModel

    var body: some View {
        AppCard {
            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TILE EDITOR")
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .tracking(1.4)
                        Text("CLICK OR DRAG TO PAINT")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .tracking(1.0)
                    }
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { model.tile.rows },
                            set: { model.resizeRows(to: $0) }
                        ),
                        in: TilePatternData.rowRange
                    ) {
                        Text("\(model.tile.rows) ROWS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(width: 54, alignment: .trailing)
                    }
                    .fixedSize()
                    Button("FILL") { model.fill() }
                        .buttonStyle(UtilityButtonStyle())
                    Button("CLEAR") { model.clear() }
                        .buttonStyle(UtilityButtonStyle())
                }

                PixelGrid(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    Label("8 × \(model.tile.rows) PIXELS", systemImage: "square.grid.3x3.fill")
                    Spacer()
                    Button("RESTORE CHECKERBOARD") { model.checkerboard() }
                        .buttonStyle(UtilityButtonStyle())
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct PalettePanel: View {
    @ObservedObject var model: TilePatternModel

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("DIGITAL RGB PALETTE")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .tracking(1.1)
                    Spacer()
                    Text("COLOR \(model.selectedColor)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 7) {
                    ForEach(0..<8, id: \.self) { color in
                        Button {
                            model.selectedColor = color
                        } label: {
                            VStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(RetroPalette.colors[color])
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(model.selectedColor == color ? .white : .white.opacity(0.18),
                                                    lineWidth: model.selectedColor == color ? 3 : 1)
                                    }
                                    .frame(height: 52)
                                    .shadow(color: model.selectedColor == color ? .white.opacity(0.22) : .clear,
                                            radius: 8)
                                Text("\(color)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(model.selectedColor == color ? .white : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("\(color): \(RetroPalette.names[color])")
                        .accessibilityLabel("Color \(color), \(RetroPalette.names[color])")
                    }
                }
            }
        }
    }
}

struct ActualSizeTileSwatch: View {
    let tile: TilePatternData
    let mode: TilePreviewMode

    var body: some View {
        Canvas { context, size in
            let dotWidth = CGFloat(mode.dotWidth)
            let dotHeight = CGFloat(mode.dotHeight)
            let columns = Int(ceil(size.width / dotWidth))
            let lines = Int(ceil(size.height / dotHeight))

            for line in 0..<lines {
                for column in 0..<columns {
                    let color = RetroPalette.colors[
                        tile[line % tile.rows, column % TilePatternData.width]
                    ]
                    let rect = CGRect(
                        x: CGFloat(column) * dotWidth,
                        y: CGFloat(line) * dotHeight,
                        width: dotWidth,
                        height: dotHeight
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mode.resolutionLabel) actual-size tiled preview")
    }
}

struct ActualSizePreviewPanel: View {
    @ObservedObject var model: TilePatternModel

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("ACTUAL SIZE PREVIEW")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .tracking(1.1)
                    Spacer()
                    Text("TILED 1:1")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    ForEach(TilePreviewMode.allCases, id: \.rawValue) { mode in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Text(mode.resolutionLabel)
                                    .foregroundStyle(.white)
                                Spacer(minLength: 2)
                                Text(mode.dotSizeLabel)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 9, weight: .bold, design: .monospaced))

                            ActualSizeTileSwatch(tile: model.tile, mode: mode)
                        }
                    }
                }
            }
        }
    }
}

struct OutputPanel: View {
    @ObservedObject var model: TilePatternModel

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("RETROBASIC OUTPUT")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .tracking(1.1)
                    Spacer()
                    Text("B / R / G")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.35, green: 0.62, blue: 1.0))
                }

                ScrollView(.horizontal, showsIndicators: true) {
                    Text(model.tile.hexExpression)
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .padding(.vertical, 15)
                        .padding(.horizontal, 16)
                }
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.36))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white.opacity(0.09), lineWidth: 1)
                        }
                }

                Text("\(model.tile.rows) ROWS  •  \(model.tile.bytes.count) BYTES  •  \(model.tile.hexPayload.count) HEX DIGITS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button {
                    model.copyExpression()
                } label: {
                    Label(model.copied ? "COPIED" : "COPY HEXCHR$", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(CopyButtonStyle(copied: model.copied))
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .accessibilityHint("Copies the complete HEXCHR dollar expression to the clipboard")
            }
        }
    }
}

struct MiniTileMark: View {
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 1)
                            .fill((row + column).isMultiple(of: 2) ? RetroPalette.colors[1] : RetroPalette.colors[3])
                    }
                }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
        .frame(width: 48, height: 48)
    }
}

struct ContentView: View {
    @StateObject private var model = TilePatternModel()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.018, green: 0.022, blue: 0.032),
                    Color(red: 0.030, green: 0.036, blue: 0.055),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                HStack(spacing: 14) {
                    MiniTileMark()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TILE PATTERN MAKER")
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .tracking(1.4)
                        Text("DIGITAL RGB TILE ENCODER")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .tracking(1.6)
                    }
                    Spacer()
                    Text("SELECT COLOR  →  PAINT  →  COPY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(1.0)
                }

                HStack(alignment: .top, spacing: 20) {
                    EditorPanel(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack(spacing: 20) {
                        PalettePanel(model: model)
                        ActualSizePreviewPanel(model: model)
                        OutputPanel(model: model)
                        AppCard {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Color(red: 0.35, green: 0.62, blue: 1.0))
                                Text("Each row becomes three bytes in Blue, Red, Green order. Bit 7 is the left-most pixel. The copied text can be pasted directly into LINE …,BF or PAINT.")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 470)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 1040, minHeight: 660)
        .preferredColorScheme(.dark)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.applicationIconImage = makeApplicationIcon()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func makeApplicationIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor(red: 0.025, green: 0.030, blue: 0.045, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 104, yRadius: 104).fill()

        let margin: CGFloat = 70
        let gap: CGFloat = 5
        let cell = (size.width - margin * 2 - gap * 7) / 8
        for row in 0..<8 {
            for column in 0..<8 {
                let color = (row + column).isMultiple(of: 2) ? RetroPalette.nsColors[1] : RetroPalette.nsColors[3]
                color.setFill()
                let x = margin + CGFloat(column) * (cell + gap)
                let y = margin + CGFloat(7 - row) * (cell + gap)
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: cell, height: cell),
                             xRadius: 6, yRadius: 6).fill()
            }
        }
        return image
    }
}

#if !SNAPSHOT
@main
struct TilePatternMakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("X1 Tile Pattern Maker") {
            ContentView()
        }
        .defaultSize(width: 1160, height: 730)
        .windowResizability(.contentMinSize)
    }
}
#endif
