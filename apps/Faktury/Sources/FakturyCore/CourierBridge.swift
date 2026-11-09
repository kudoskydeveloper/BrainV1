import Foundation

/// Hands an invoice to Courier (the user's mail app) as a draft with the PDF attached, through Courier's own MCP server.
/// Nothing is ever sent from here: the user sends the draft in Courier.
public enum CourierBridge {
    public static var mcpPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Courier.app/Contents/MacOS/courier-mcp").path
    }
    public static var available: Bool { FileManager.default.isExecutableFile(atPath: mcpPath) }

    /// Runs one Courier MCP tool and returns its text result.
    public static func call(_ tool: String, _ args: [String: Any], timeout: TimeInterval = 90) throws -> String {
        guard available else { throw FakturyError("Courier nie je nainštalovaný (~/Applications/Courier.app).") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: mcpPath)
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run()
        func send(_ obj: [String: Any]) {
            var d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            d.append(0x0A)
            input.fileHandleForWriting.write(d)
        }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                                                                             "clientInfo": ["name": "faktury", "version": "0.1"]]])
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": tool, "arguments": args]])
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        defer { try? input.fileHandleForWriting.close(); if p.isRunning { p.terminate() } }
        let fh = output.fileHandleForReading
        while Date() < deadline {
            let chunk = fh.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            for line in buffer.split(separator: 0x0A) {
                guard let msg = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], (msg["id"] as? Int) == 2 else { continue }
                if let e = msg["error"] as? [String: Any] { throw FakturyError("Courier: \(e["message"] ?? "chyba")") }
                let r = msg["result"] as? [String: Any] ?? [:]
                let text = (r["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
                if r["isError"] as? Bool == true { throw FakturyError("Courier: \(text)") }
                return text
            }
        }
        throw FakturyError("Courier neodpovedal.")
    }

    /// The Courier accounts (e-mail addresses) to send from.
    public static func accounts() -> [String] {
        guard let text = try? call("accounts", [:], timeout: 15), let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { $0["email"] as? String }
    }

    public static func subject(_ i: Invoice, company: Company) -> String { "\(i.kind.title) \(i.number ?? "") – \(company.shortName)" }

    public static func body(_ i: Invoice, company: Company) -> String {
        var lines = ["Dobrý deň,", ""]
        switch i.kind {
        case .creditNote:
            lines.append("v prílohe posielam dobropis č. \(i.number ?? "") k faktúre č. \(i.creditsNumber ?? "") na sumu \(Money.string(abs(i.totalCents), currency: i.currency)).")
        case .proforma:
            lines.append("v prílohe posielam zálohovú faktúru č. \(i.number ?? "") na sumu \(Money.string(i.totalCents, currency: i.currency)) so splatnosťou \(Day.sk(i.dueDate)).")
        case .invoice:
            lines.append("v prílohe posielam faktúru č. \(i.number ?? "") na sumu \(Money.string(i.totalCents, currency: i.currency)) so splatnosťou \(Day.sk(i.dueDate)).")
        }
        if i.kind != .creditNote && i.paymentMethod == .transfer {
            lines += ["", "IBAN: \(Validation.formatIBAN(company.iban))", "Variabilný symbol: \(i.variableSymbol)",
                      "Na faktúre je aj QR kód PAY by square na rýchlu platbu."]
        }
        lines += ["", "Ďakujem."]
        return lines.joined(separator: "\n")
    }

    /// A Courier draft to the client's invoice e-mail with the PDF. Returns Courier's preview text.
    @discardableResult
    public static func draft(_ i: Invoice, company: Company, to: String? = nil, body: String? = nil) throws -> String {
        guard i.status == .issued, let pdf = i.pdfPath else { throw FakturyError("Poslať sa dá len vystavený doklad.") }
        let recipient = (to ?? i.client.email).trimmingCharacters(in: .whitespaces)
        guard !recipient.isEmpty else { throw FakturyError("Odberateľ \(i.client.name) nemá e-mail na faktúry.") }
        var args: [String: Any] = ["to": recipient, "subject": subject(i, company: company), "body": body ?? self.body(i, company: company), "attachments": [pdf]]
        let sender = company.senderEmail.isEmpty ? company.email : company.senderEmail
        if !sender.isEmpty { args["account"] = sender }
        return try call("draft", args)
    }
}
