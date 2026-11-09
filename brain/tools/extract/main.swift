// brain-extract <file> [--pages 1-5] [--ocr auto|force|off]
// PDF: text layer per page (PDFKit); pages without text are rendered and OCR'd with Vision. Images: Vision OCR.
// Output: plain text, pages separated by "--- page N ---". Everything runs locally.
import AppKit
import PDFKit
import Vision

let args = CommandLine.arguments
guard args.count > 1 else { FileHandle.standardError.write("usage: brain-extract <file> [--pages a-b] [--ocr auto|force|off]\n".data(using: .utf8)!); exit(2) }
let url = URL(fileURLWithPath: args[1])
func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let ocrMode = opt("--ocr") ?? "auto"
let langs = ["cs-CZ", "en-US", "pl-PL", "de-DE"]   // Vision has no Slovak; Czech covers nearly all of it

func ocr(_ cg: CGImage) -> String {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = langs
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

func render(_ page: PDFPage) -> CGImage? {
    let box = page.bounds(for: .mediaBox), scale: CGFloat = 2.5   // ~180 dpi, good for OCR
    let w = Int(box.width * scale), h = Int(box.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

let ext = url.pathExtension.lowercased()
if ext == "pdf" {
    guard let doc = PDFDocument(url: url) else { print("ERROR: cannot open PDF"); exit(1) }
    var from = 1, to = doc.pageCount
    if let r = opt("--pages") { let p = r.split(separator: "-").compactMap { Int($0) }; from = max(1, p.first ?? 1); to = min(doc.pageCount, p.last ?? from) }
    print("[PDF, \(doc.pageCount) pages]")
    for i in (from - 1)..<to {
        guard let page = doc.page(at: i) else { continue }
        var text = page.string ?? ""
        var how = "text"
        if ocrMode == "force" || (ocrMode == "auto" && text.trimmingCharacters(in: .whitespacesAndNewlines).count < 25), let img = render(page) {
            text = ocr(img); how = "ocr"
        }
        print("--- page \(i + 1) (\(how)) ---\n\(text)")
    }
} else {
    guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("ERROR: unsupported file"); exit(1) }
    print("[image \(cg.width)x\(cg.height), ocr]\n" + ocr(cg))
}
