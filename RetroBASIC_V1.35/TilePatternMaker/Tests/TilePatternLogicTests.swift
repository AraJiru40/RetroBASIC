import Foundation

@main
struct TilePatternLogicTests {
    static func main() {
        encodeDigitalRGBPlanes()
        encodeReferenceCheckerboard()
        preservePixelsWhenResizing()
        useRetroBASICDotGeometry()
        print("TilePatternLogicTests: OK")
    }

    private static func encodeDigitalRGBPlanes() {
        var tile = TilePatternData(rows: 1, checkerboard: false)
        for color in 0..<8 {
            tile.paint(row: 0, column: color, color: color)
        }
        expect(tile.hexPayload, "55330F", "B/R/G plane encoding")
        expect(tile.hexExpression, "HEXCHR$(\"55330F\")", "complete expression")
    }

    private static func encodeReferenceCheckerboard() {
        let tile = TilePatternData(rows: 2)
        expect(tile.groupedHexPayload, "FF5500 FFAA00", "blue/magenta checkerboard")
    }

    private static func preservePixelsWhenResizing() {
        var tile = TilePatternData(rows: 2, checkerboard: false)
        tile.paint(row: 1, column: 7, color: 6)
        tile.resizeRows(to: 4)
        guard tile.rows == 4, tile[1, 7] == 6, tile[3, 7] == 0 else {
            fatalError("row resize did not preserve and extend the tile")
        }
        tile.resizeRows(to: 1)
        guard tile.rows == 1, tile.pixels.count == 8 else {
            fatalError("row resize did not truncate the tile")
        }
    }

    private static func useRetroBASICDotGeometry() {
        guard TilePreviewMode.highResolution.screenWidth == 640,
              TilePreviewMode.highResolution.dotWidth == 1,
              TilePreviewMode.highResolution.dotHeight == 2,
              TilePreviewMode.lowResolution.screenWidth == 320,
              TilePreviewMode.lowResolution.dotWidth == 2,
              TilePreviewMode.lowResolution.dotHeight == 2 else {
            fatalError("actual-size preview geometry does not match RetroBASIC")
        }
    }

    private static func expect(_ actual: String, _ expected: String, _ name: String) {
        guard actual == expected else {
            fatalError("\(name): expected [\(expected)], got [\(actual)]")
        }
    }
}
