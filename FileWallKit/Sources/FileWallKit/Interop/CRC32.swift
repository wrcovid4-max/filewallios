import Foundation

/// IEEE CRC-32, the checksum ZIP local/central headers require. Implemented here
/// rather than pulled from zlib because Apple's Compression framework does not
/// expose `crc32`, and the whole project forbids third-party dependencies.
///
/// Standard reflected polynomial 0xEDB88320. Streamable via `update`.
struct CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private var crc: UInt32 = 0xFFFFFFFF

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
    }

    var value: UInt32 { crc ^ 0xFFFFFFFF }

    static func checksum(_ data: Data) -> UInt32 {
        var c = CRC32()
        c.update(data)
        return c.value
    }
}
