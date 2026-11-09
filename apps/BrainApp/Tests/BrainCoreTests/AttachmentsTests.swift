import AppKit
import XCTest
@testable import BrainCore

final class AttachmentsTests: XCTestCase {
    func testStoreScalesDownAndMessageCarriesImage() throws {
        // a 3000×2000 PNG becomes a JPEG of at most 1568 px
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 2000, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = try XCTUnwrap(Attachments.store(png))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "jpg")
        let stored = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        XCTAssertEqual(max(stored.pixelsWide, stored.pixelsHigh), Attachments.maxPixels)
        XCTAssertTrue(Attachments.isImage(url))

        let line = try XCTUnwrap(Attachments.userMessage(text: "Čo to je?", images: [url]))
        let m = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let content = try XCTUnwrap((m["message"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "text"])
        XCTAssertEqual((content[0]["source"] as? [String: Any])?["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(content[1]["text"] as? String, "Čo to je?")
        XCTAssertFalse(line.contains("\n"))
    }

    func testNotAnImage() {
        XCTAssertNil(Attachments.store(Data("hello".utf8)))
        XCTAssertFalse(Attachments.isImage(URL(fileURLWithPath: "/tmp/a.pdf")))
    }
}
