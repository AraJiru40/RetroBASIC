import Foundation

/// The one-byte character set used by the NEC PC-8001/8801 family.
///
/// Swift joins a halfwidth katakana and its dakuten into one `Character`.
/// The original machines stored them as two bytes, so extended characters are
/// represented internally by one private-use scalar per byte. Files and copied
/// screen text are converted back to ordinary Unicode by `displayString`.
enum RetroCharset {
    private static let storageBase: UInt32 = 0xE100

    static let kanaCodes: [UInt8] = Array(0xA1...0xDF)
    static let graphicCodes: [UInt8] = Array(0x80...0x9F) + Array(0xE0...0xF7)

    /// Unicode counterparts used when saving and copying. The exact on-screen
    /// shapes still come from the 8x8 character data, never from a system font.
    private static let graphicUnicode: [UInt8: Unicode.Scalar] = {
        let pairs: [(UInt8, String)] = [
            (0x80, "▁"), (0x81, "▂"), (0x82, "▃"), (0x83, "▄"),
            (0x84, "▅"), (0x85, "▆"), (0x86, "▇"), (0x87, "█"),
            (0x88, "▏"), (0x89, "▎"), (0x8A, "▍"), (0x8B, "▌"),
            (0x8C, "▋"), (0x8D, "▊"), (0x8E, "▉"), (0x8F, "┼"),
            (0x90, "┴"), (0x91, "┬"), (0x92, "┤"), (0x93, "├"),
            (0x94, "▔"), (0x95, "─"), (0x96, "│"), (0x97, "▕"),
            (0x98, "┌"), (0x99, "┐"), (0x9A, "└"), (0x9B, "┘"),
            (0x9C, "╭"), (0x9D, "╮"), (0x9E, "╯"), (0x9F, "╰"),
            (0xE0, "═"), (0xE1, "╠"), (0xE2, "╬"), (0xE3, "╣"),
            (0xE4, "◢"), (0xE5, "◣"), (0xE6, "◤"), (0xE7, "◥"),
            (0xE8, "♠"), (0xE9, "♥"), (0xEA, "♦"), (0xEB, "♣"),
            (0xEC, "●"), (0xED, "○"), (0xEE, "╱"), (0xEF, "╲"),
            (0xF0, "╳"), (0xF1, "円"), (0xF2, "年"), (0xF3, "月"),
            (0xF4, "日"), (0xF5, "時"), (0xF6, "分"), (0xF7, "秒"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.compactMap { code, text in
            text.unicodeScalars.first.map { (code, $0) }
        })
    }()

    static func character(forByte byte: UInt8) -> Character {
        if byte < 0x80 { return Character(UnicodeScalar(UInt32(byte))!) }
        return Character(UnicodeScalar(storageBase + UInt32(byte))!)
    }

    static func byte(for character: Character) -> UInt8? {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return nil }
        if value < 0x80 { return UInt8(value) }
        if value >= storageBase, value <= storageBase + 0xFF {
            return UInt8(value - storageBase)
        }
        if value >= 0xFF61, value <= 0xFF9F {
            return UInt8(value - 0xFF61 + 0xA1)
        }
        return nil
    }

    static func displayCharacter(forByte byte: UInt8) -> Character {
        if byte >= 0xA1, byte <= 0xDF {
            return Character(UnicodeScalar(0xFF61 + UInt32(byte - 0xA1))!)
        }
        if let scalar = graphicUnicode[byte] { return Character(scalar) }
        return character(forByte: byte)
    }

    /// Convert pasted, loaded, or source-code Unicode to byte-stable storage.
    static func storageString(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value >= 0xFF61, value <= 0xFF9F {
                result.append(character(forByte: UInt8(value - 0xFF61 + 0xA1)))
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Convert internal one-byte characters to portable Unicode for UI/files.
    static func displayString(_ text: String) -> String {
        var result = ""
        for character in text {
            if let code = byte(for: character), code >= 0x80 {
                result.append(displayCharacter(forByte: code))
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// SAVE keeps GRPH bytes in the private-use range so ordinary Japanese
    /// such as `日時` cannot be mistaken for the one-cell GRPH versions when
    /// the UTF-8 file is loaded again. Katakana remain human-readable.
    static func fileString(_ text: String) -> String {
        var result = ""
        for character in text {
            if let code = byte(for: character), code >= 0xA1, code <= 0xDF {
                result.append(displayCharacter(forByte: code))
            } else {
                result.append(character)
            }
        }
        return result
    }

    static func length(of text: String) -> Int { storageString(text).count }
}
