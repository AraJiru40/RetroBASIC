import AppKit
import SwiftUI

@main
struct AppInteractionTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let model = TilePatternModel()

        model.selectedColor = 6
        model.paint(row: 0, column: 0)
        guard model.tile.hexPayload == "7FD580FFAA00FF5500FFAA00" else {
            fatalError("painting did not update the generated hexadecimal data")
        }

        var copiedText: String?
        model.copyExpression { expression in
            copiedText = expression
            return true
        }
        guard copiedText == model.tile.hexExpression, model.copied else {
            fatalError("COPY did not place the complete expression on the pasteboard")
        }

        print("AppInteractionTests: OK")
    }
}
