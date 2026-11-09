import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The model, through the claude CLI with the user's own sign-in (the same way Brain translates meeting notes): no tools,
/// no MCP, no settings, no session. Answers are JSON; each one is cached in the store by its input.
public enum AI {
    public static var model = ProcessInfo.processInfo.environment["RECEPTY_MODEL"] ?? "sonnet"

    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.npm-global/bin/claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Without the variables of a Claude Code session that may have started us: with them claude looks for that session's login.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { k, _ in !k.hasPrefix("CLAUDE") && !["AI_AGENT", "BAGGAGE", "__CFBundleIdentifier"].contains(k) }
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.npm-global/bin:/usr/bin:/bin"
        return env
    }

    public static var available: Bool { claudePath != nil }

    /// Runs one prompt and returns the text answer. Images (JPEG data) go along as pictures the model looks at, through
    /// `--input-format stream-json` (as Brain's panel sends attachments).
    static func run(system: String, input: String, images: [Data] = [], timeout: TimeInterval = 300) async throws -> String {
        guard let claude = claudePath else { throw ReceptyError("Nenašiel som claude CLI (prihlásenie ako v Brain).") }
        let stream = !images.isEmpty
        return try await withCheckedThrowingContinuation { cont in
            let p = Process(), out = Pipe(), err = Pipe(), inp = Pipe()
            p.executableURL = URL(fileURLWithPath: claude)
            p.arguments = ["-p"] + (stream ? ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose"] : ["--output-format", "text"])
                + ["--model", model, "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence", "--system-prompt", system]
            p.environment = environment
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            p.standardInput = inp; p.standardOutput = out; p.standardError = err
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            // Read output while the process runs: a big answer would fill the pipe and stall it.
            let buf = OutputBuffer()
            out.fileHandleForReading.readabilityHandler = { h in buf.append(h.availableData) }
            p.terminationHandler = { proc in
                killer.cancel()
                out.fileHandleForReading.readabilityHandler = nil
                buf.append(out.fileHandleForReading.readDataToEndOfFile())
                let raw = String(decoding: buf.data, as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                var o = raw
                if stream {
                    // The last "result" event carries the answer.
                    o = raw.split(separator: "\n").reversed().lazy.compactMap { line -> String? in
                        guard let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], j["type"] as? String == "result" else { return nil }
                        return (j["result"] as? String) ?? ""
                    }.first ?? ""
                }
                if proc.terminationStatus == 0, !o.isEmpty { cont.resume(returning: o) }
                else { cont.resume(throwing: ReceptyError("Model zlyhal: \(String((e.isEmpty ? o : e).prefix(300)))")) }
            }
            do { try p.run() } catch { cont.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            if stream {
                var content: [[String: Any]] = images.map { ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]] }
                content.append(["type": "text", "text": input])
                let m: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
                inp.fileHandleForWriting.write((try? JSONSerialization.data(withJSONObject: m)) ?? Data())
                inp.fileHandleForWriting.write(Data([0x0A]))
            } else {
                inp.fileHandleForWriting.write(Data(input.utf8))
            }
            try? inp.fileHandleForWriting.close()
        }
    }

    /// A photo (any format ImageIO reads, also HEIC; not PDF) as a JPEG at most `side` px, for the model.
    public static func jpeg(_ url: URL, side: Int = 1800) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }

    static func key(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// JSON object from the model (cached by system + input), tried twice when the answer doesn't parse.
    public static func json(system: String, input: Any, images: [Data] = [], store: Store?) async throws -> [String: Any] {
        let inData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])
        let inText = String(decoding: inData, as: UTF8.self)
        let k = key([model, system, inText] + images.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
        if let c = store?.cached(k), let o = parse(c) { return o }
        var last: Error = ReceptyError("Model nevrátil JSON.")
        for _ in 0..<2 {
            do {
                let out = try await run(system: system, input: inText, images: images)
                if let o = parse(out) { store?.cache(k, out); return o }
            } catch { last = error }
        }
        throw last
    }

    static func parse(_ s: String) -> [String: Any]? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(s[a...b].utf8))) as? [String: Any]
    }
}

/// What a process writes, collected from the pipe's handler thread.
final class OutputBuffer: @unchecked Sendable {
    private var d = Data()
    private let lock = NSLock()
    func append(_ x: Data) { lock.lock(); d.append(x); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return d }
}

// Small helpers for reading model JSON.
func num(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
    return nil
}
func text(_ v: Any?) -> String { (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (v as? NSNumber)?.stringValue ?? "" }
