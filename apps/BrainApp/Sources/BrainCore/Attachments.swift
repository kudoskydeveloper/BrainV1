import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures attached to a question in the panel: kept as JPEG files (at most 1568 px, what Claude sees anyway) in
/// ~/Library/Application Support/Brain/attachments, sent to the model as images (vision) and named by path for Brain's tools.
public enum Attachments {
    public static let dir = Runner.home.appendingPathComponent("Library/Application Support/Brain/attachments")
    public static let maxPixels = 1568

    /// Image data (HEIC, JPEG, PNG, …) → a stored JPEG, oriented upright and scaled down; nil when it isn't an image.
    public static func store(_ data: Data) -> URL? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return store(src)
    }

    /// An image file (from Finder or Photos) → a stored JPEG; nil when it isn't an image.
    public static func store(file: URL) -> URL? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return store(src)
    }

    static func store(_ src: CGImageSource) -> URL? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard CGImageSourceGetCount(src) > 0, let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("\(Self.stamp())-\(UUID().uuidString.prefix(6)).jpg")
        guard let dst = CGImageDestinationCreateWithURL(f as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? f : nil
    }

    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    /// Image files Claude can take as image blocks.
    public static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// One `--input-format stream-json` line: the pictures as base64 image blocks, then the text.
    public static func userMessage(text: String, images: [URL]) -> String? {
        var content: [[String: Any]] = images.compactMap { url in
            guard let d = try? Data(contentsOf: url) else { return nil }
            return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": d.base64EncodedString()]]
        }
        content.append(["type": "text", "text": text])
        let m: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard let d = try? JSONSerialization.data(withJSONObject: m) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}
