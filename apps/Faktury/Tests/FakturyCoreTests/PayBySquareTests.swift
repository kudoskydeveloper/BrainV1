import Foundation
import Testing
@testable import FakturyCore

@Suite struct PayBySquareTests {
    func sample() -> PayBySquare.Payment {
        var p = PayBySquare.Payment(amount: Decimal(string: "1234.50")!, iban: "SK31 1200 0000 1987 4263 7541")
        p.dueDate = "2026-11-30"; p.variableSymbol = "20260012"; p.note = "Faktúra 20260012"; p.swift = "TATRSKBX"
        p.beneficiaryName = "10T Studios s.r.o."
        return p
    }

    @Test func roundTrip() throws {
        let p = sample()
        let qr = try PayBySquare.encode(p)
        #expect(PayBySquare.decode(qr) == PayBySquare.serialize(p))
        if let out = ProcessInfo.processInfo.environment["BYSQUARE_OUT"] { try qr.write(toFile: out, atomically: true, encoding: .utf8) }
    }

    @Test func serialized() {
        let s = PayBySquare.serialize(sample()).components(separatedBy: "\t")
        #expect(s[3] == "1234.5")
        #expect(s[5] == "20261130")
        #expect(s[12] == "SK3112000000198742637541")
    }

    @Test func crc() { #expect(PayBySquare.crc32(Array("123456789".utf8)) == 0xCBF43926) }

    @Test func qr() throws {
        let m = PayBySquare.qrMatrix(try PayBySquare.encode(sample()))
        #expect((m?.count ?? 0) > 20)
    }
}
