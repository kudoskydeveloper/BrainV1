import CLZMA
import CoreImage
import Foundation

/// PAY by square (Slovak banking QR standard, version 1.1.0): payment order fields, tab separated, CRC32 in front,
/// raw LZMA1, a 2-byte header plus 2-byte length, base32hex. Every Slovak banking app reads it.
public enum PayBySquare {
    public struct Payment: Equatable {
        public var amount: Decimal
        public var currency = "EUR"
        public var dueDate: String?            // yyyy-MM-dd
        public var variableSymbol = ""
        public var constantSymbol = ""
        public var specificSymbol = ""
        public var note = ""
        public var iban: String
        public var swift = ""
        public var beneficiaryName = ""
        public var beneficiaryStreet = ""
        public var beneficiaryCity = ""
        public init(amount: Decimal, iban: String) { self.amount = amount; self.iban = iban }
    }

    /// The tab separated payload before checksum and compression.
    public static func serialize(_ p: Payment) -> String {
        var f: [String] = []
        f.append("")                                   // invoice id
        f.append("1")                                  // number of payments
        f.append("1")                                  // payment order
        f.append(amountString(p.amount))
        f.append(p.currency)
        f.append(p.dueDate.map { $0.replacingOccurrences(of: "-", with: "") } ?? "")
        f.append(digits(p.variableSymbol, max: 10))
        f.append(digits(p.constantSymbol, max: 4))
        f.append(digits(p.specificSymbol, max: 10))
        f.append("")                                   // originator's reference
        f.append(clean(p.note, max: 140))
        f.append("1")                                  // number of bank accounts
        f.append(p.iban.replacingOccurrences(of: " ", with: "").uppercased())
        f.append(p.swift.replacingOccurrences(of: " ", with: "").uppercased())
        f.append("0")                                  // standing order extension
        f.append("0")                                  // direct debit extension
        f.append(clean(p.beneficiaryName, max: 70))    // 1.1.0: beneficiary
        f.append(clean(p.beneficiaryStreet, max: 70))
        f.append(clean(p.beneficiaryCity, max: 70))
        return f.joined(separator: "\t")
    }

    public static func encode(_ p: Payment) throws -> String {
        let payload = Array(serialize(p).utf8)
        var crc = crc32(payload)
        var data = withUnsafeBytes(of: &crc) { Array($0) }   // little endian
        data += payload
        guard data.count <= 0xFFFF else { throw FakturyError("PAY by square: príliš veľa údajov.") }
        var out = [UInt8](repeating: 0, count: data.count + 1024)
        var outPos = 0
        let r = clzma_bysquare_encode(data, data.count, &out, &outPos, out.count)
        guard r == 0 else { throw FakturyError("PAY by square: LZMA zlyhalo (\(r)).") }
        // header: type 0 (pay) << 4 | version 1 (1.1.0); document type 0 << 4 | reserved 0; then data length LE
        var bytes: [UInt8] = [0x01, 0x00, UInt8(data.count & 0xFF), UInt8(data.count >> 8)]
        bytes += out[0..<outPos]
        return base32hex(bytes)
    }

    /// Back from the QR text to the payload (for tests).
    public static func decode(_ text: String) -> String? {
        guard let bytes = unbase32hex(text), bytes.count > 4 else { return nil }
        let length = Int(bytes[2]) | Int(bytes[3]) << 8
        let compressed = Array(bytes[4...])
        var out = [UInt8](repeating: 0, count: length + 64)
        var outPos = 0
        let r = clzma_bysquare_decode(compressed, compressed.count, &out, &outPos, out.count)
        guard r == 0 || r == 1 || outPos >= length, outPos >= 4 else { return nil }
        let data = Array(out[0..<min(outPos, length)])
        let payload = Array(data[4...])
        let crc = UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
        guard crc == crc32(payload) else { return nil }
        return String(decoding: payload, as: UTF8.self)
    }

    // MARK: - QR

    /// The QR modules (true = dark), quiet zone included, for drawing as vector squares.
    public static func qrMatrix(_ text: String) -> [[Bool]]? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let img = f.outputImage else { return nil }
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        let w = Int(img.extent.width), h = Int(img.extent.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(img, toBitmap: &px, rowBytes: w * 4, bounds: img.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0..<h).map { y in (0..<w).map { x in px[(y * w + x) * 4] < 128 } }
    }

    // MARK: - Helpers

    static func amountString(_ d: Decimal) -> String {
        var v = d, r = Decimal()
        NSDecimalRound(&r, &v, 2, .plain)
        let s = NSDecimalNumber(decimal: r).stringValue
        return s
    }

    static func digits(_ s: String, max: Int) -> String { String(s.filter(\.isNumber).prefix(max)) }
    /// Without diacritics (like the reference bysquare library: some banking apps garble them) and without tabs.
    static func clean(_ s: String, max: Int) -> String {
        let plain = s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "sk_SK"))
        return String(plain.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").prefix(max))
    }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUV")

    static func base32hex(_ bytes: [UInt8]) -> String {
        var out = "", buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(buffer >> bits) & 31]) }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    static func unbase32hex(_ s: String) -> [UInt8]? {
        var out: [UInt8] = [], buffer = 0, bits = 0
        for ch in s.uppercased() {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | v; bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((buffer >> bits) & 0xFF)) }
            buffer &= (1 << bits) - 1
        }
        return out
    }
}
