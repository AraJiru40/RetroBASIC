import Foundation

/// RetroBASIC's zoom-1 dot geometry for each supported graphics mode.
enum TilePreviewMode: Int, CaseIterable {
    case highResolution = 640
    case lowResolution = 320

    static let screenHeight = 200

    var screenWidth: Int { rawValue }
    var dotWidth: Int { self == .highResolution ? 1 : 2 }
    var dotHeight: Int { 2 }
    var resolutionLabel: String { "\(screenWidth) × \(Self.screenHeight)" }
    var dotSizeLabel: String { "\(dotWidth) × \(dotHeight) DOT" }
}

/// An 8 x n Hu-BASIC digital-RGB tile.
///
/// Every row is encoded as three bytes in blue, red, green order. Bit 7 is
/// the left-most pixel and bit 0 is the right-most pixel.
struct TilePatternData: Equatable {
    static let width = 8
    static let rowRange = 1...16

    private(set) var rows: Int
    private(set) var pixels: [Int]

    init(rows: Int = 4, checkerboard: Bool = true) {
        self.rows = min(max(rows, Self.rowRange.lowerBound), Self.rowRange.upperBound)
        self.pixels = Array(repeating: 0, count: Self.width * self.rows)
        if checkerboard {
            makeCheckerboard(first: 1, second: 3)
        }
    }

    subscript(row: Int, column: Int) -> Int {
        guard row >= 0, row < rows, column >= 0, column < Self.width else { return 0 }
        return pixels[row * Self.width + column]
    }

    mutating func paint(row: Int, column: Int, color: Int) {
        guard row >= 0, row < rows, column >= 0, column < Self.width else { return }
        pixels[row * Self.width + column] = min(max(color, 0), 7)
    }

    mutating func resizeRows(to requestedRows: Int) {
        let newRows = min(max(requestedRows, Self.rowRange.lowerBound), Self.rowRange.upperBound)
        guard newRows != rows else { return }
        var resized = Array(repeating: 0, count: Self.width * newRows)
        let copiedRows = min(rows, newRows)
        for row in 0..<copiedRows {
            let source = row * Self.width
            let destination = row * Self.width
            resized.replaceSubrange(destination..<(destination + Self.width),
                                    with: pixels[source..<(source + Self.width)])
        }
        rows = newRows
        pixels = resized
    }

    mutating func clear() {
        pixels = Array(repeating: 0, count: Self.width * rows)
    }

    mutating func fill(with color: Int) {
        pixels = Array(repeating: min(max(color, 0), 7), count: Self.width * rows)
    }

    mutating func makeCheckerboard(first: Int = 1, second: Int = 3) {
        let a = min(max(first, 0), 7)
        let b = min(max(second, 0), 7)
        for row in 0..<rows {
            for column in 0..<Self.width {
                paint(row: row, column: column, color: (row + column).isMultiple(of: 2) ? a : b)
            }
        }
    }

    var bytes: [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(rows * 3)
        for row in 0..<rows {
            for plane in 0..<3 {
                var byte: UInt8 = 0
                for column in 0..<Self.width where self[row, column] & (1 << plane) != 0 {
                    byte |= UInt8(1 << (7 - column))
                }
                result.append(byte)
            }
        }
        return result
    }

    var hexPayload: String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    var groupedHexPayload: String {
        stride(from: 0, to: bytes.count, by: 3).map { offset in
            bytes[offset..<min(offset + 3, bytes.count)]
                .map { String(format: "%02X", $0) }
                .joined()
        }.joined(separator: " ")
    }

    var hexExpression: String {
        "HEXCHR$(\"\(hexPayload)\")"
    }
}
