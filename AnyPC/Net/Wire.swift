import Foundation

/// Constants and binary framing shared with the desktop app. See docs/PROTOCOL.md.
enum Wire {
    static let version = 1
    static let defaultPort = 47800
    static let path = "/anypc"
    static let serviceType = "_anypc._tcp"

    static let frameType: UInt8 = 0x01
    static let downloadChunkType: UInt8 = 0x02
    static let uploadChunkType: UInt8 = 0x03
    static let frameHeaderSize = 13
    static let chunkHeaderSize = 5
    static let chunkSize = 64 * 1024

    static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        let a = UInt32(b[i]) << 24
        let c = UInt32(b[i + 1]) << 16
        let d = UInt32(b[i + 2]) << 8
        return a | c | d | UInt32(b[i + 3])
    }

    static func readU16(_ b: [UInt8], _ i: Int) -> Int {
        return (Int(b[i]) << 8) | Int(b[i + 1])
    }

    static func chunk(type: UInt8, id: UInt32, payload: Data) -> Data {
        var d = Data(capacity: chunkHeaderSize + payload.count)
        d.append(type)
        d.append(UInt8((id >> 24) & 0xFF))
        d.append(UInt8((id >> 16) & 0xFF))
        d.append(UInt8((id >> 8) & 0xFF))
        d.append(UInt8(id & 0xFF))
        d.append(payload)
        return d
    }
}

/// Windows virtual-key codes.
enum VK {
    static let back: UInt16 = 0x08
    static let tab: UInt16 = 0x09
    static let enter: UInt16 = 0x0D
    static let escape: UInt16 = 0x1B
    static let space: UInt16 = 0x20
    static let pageUp: UInt16 = 0x21
    static let pageDown: UInt16 = 0x22
    static let end: UInt16 = 0x23
    static let home: UInt16 = 0x24
    static let left: UInt16 = 0x25
    static let up: UInt16 = 0x26
    static let right: UInt16 = 0x27
    static let down: UInt16 = 0x28
    static let printScreen: UInt16 = 0x2C
    static let insert: UInt16 = 0x2D
    static let delete: UInt16 = 0x2E
    static let win: UInt16 = 0x5B

    /// F1 ... F12
    static func f(_ n: Int) -> UInt16 { UInt16(0x6F + n) }

    /// Maps a typed character to a key, for shortcuts like Ctrl+C.
    static func forCharacter(_ ch: Character) -> UInt16? {
        let s = String(ch).lowercased()
        guard let scalar = s.unicodeScalars.first, s.unicodeScalars.count == 1 else { return nil }
        let v = scalar.value
        if v >= 97 && v <= 122 { return UInt16(0x41 + v - 97) } // a-z
        if v >= 48 && v <= 57 { return UInt16(0x30 + v - 48) }  // 0-9
        switch s {
        case " ": return space
        case "\n": return enter
        case "\t": return tab
        case ";": return 0xBA
        case "=": return 0xBB
        case ",": return 0xBC
        case "-": return 0xBD
        case ".": return 0xBE
        case "/": return 0xBF
        case "`": return 0xC0
        case "[": return 0xDB
        case "\\": return 0xDC
        case "]": return 0xDD
        case "'": return 0xDE
        default: return nil
        }
    }
}

struct AnyPCError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
